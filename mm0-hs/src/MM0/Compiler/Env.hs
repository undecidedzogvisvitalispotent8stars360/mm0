{-# LANGUAGE RankNTypes #-}
module MM0.Compiler.Env (module MM0.Compiler.Env, Offset, SortData, Visibility(..),
  Ident, Sort, TermName, ThmName, VarName, Token,
  Binder, DepType(..), PBinder(..), SExpr(..),
  binderName, binderType, binderBound,
  Prec(..), TVar) where

import Control.Concurrent.STM
import Control.Concurrent hiding (newMVar)
import Control.Concurrent.Async.Pool
import Control.Monad.Trans.Maybe
import Control.Monad.RWS.Strict
import Data.Bits
import Data.Char
import Data.Maybe
import Data.List
import Data.Word8
import Data.Text (Text)
import Data.Default
import qualified Data.IntMap as I
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as H
import qualified Data.HashSet as HS
import qualified Data.Text as T
import qualified Data.Vector.Mutable.Dynamic as VD
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import System.Timeout
import System.IO.Unsafe
import MM0.Compiler.AST (Offset, Range,
  Binder(..), SortData(..), Prec(..), Visibility(..), QExpr)
import MM0.Kernel.Environment (Ident, Sort, TermName, ThmName, VarName, Token,
  PBinder(..), SExpr(..), DepType(..), binderName, binderType, binderBound)
import Text.Megaparsec (errorOffset, parseErrorTextPretty)
import MM0.Compiler.Parser (ParseError)

-- (<!>) :: (HasCallStack) => H.HashMap T.Text v -> T.Text -> v
-- (<!>) m k = case H.lookup k m of Nothing -> error $ "<!>" ++ show k; Just a -> a

data Proof =
    ProofHyp VarName
  | ProofThm ThmName [SExpr] [Proof]
  | ProofConv SExpr Conv Proof
  | ProofLet VarName Proof Proof

data Conv =
    CVar VarName
  | CApp TermName [Conv]
  | CSym Conv
  | CUnfold TermName [SExpr] [VarName] Conv

data Syntax = Define | Lambda | Quote | If | Focus | Let | Letrec

instance Show Syntax where
  showsPrec _ Define = ("def" ++)
  showsPrec _ Lambda = ("fn" ++)
  showsPrec _ Quote = ("quote" ++)
  showsPrec _ If = ("if" ++)
  showsPrec _ Focus = ("focus" ++)
  showsPrec _ Let = ("let" ++)
  showsPrec _ Letrec = ("letrec" ++)

type Proc = Range -> [LispVal] -> ElabM LispVal

data LispVal =
    Atom Offset T.Text
  | List [LispVal]
  | DottedList LispVal [LispVal] LispVal
  | Number Integer
  | String T.Text
  | UnparsedFormula Offset T.Text
  | Bool Bool
  | Syntax Syntax
  | Undef
  | Proc Proc
  | Ref (TVar LispVal)
  | MVar Int Offset Sort Bool
  | Goal Offset LispVal

alphanumber :: Int -> T.Text
alphanumber = T.reverse . T.pack . go . (+1) where
  go 0 = ""
  go n = let (q, r) = quotRem (n - 1) 26 in
    chr (r + ord 'a') : go q

instance Show LispVal where
  showsPrec _ (Atom _ e) = (T.unpack e ++)
  showsPrec _ (List [Syntax Quote, e]) = ('\'' :) . shows e
  showsPrec _ (List ls) = ('(' :) . f ls . (')' :) where
    f [] = id
    f [e] = shows e
    f (e : es) = shows e . (' ' :) . f es
  showsPrec _ (DottedList l ls e') =
    ('(' :) . flip (foldr (\e -> shows e . (' ' :))) (l : ls) .
    (". " ++) . shows e' . (')' :)
  showsPrec _ (Number n) = shows n
  showsPrec _ (String s) = shows s
  showsPrec _ (Bool True) = ("#t" ++)
  showsPrec _ (Bool False) = ("#f" ++)
  showsPrec _ (UnparsedFormula _ f) = ('$' :) . (T.unpack f ++) . ('$' :)
  showsPrec _ (Syntax s) = shows s
  showsPrec _ Undef = ("#<undef>" ++)
  showsPrec _ (Proc _) = ("#<closure>" ++)
  showsPrec _ (Ref e) = shows (unsafePerformIO (readTVarIO e))
  showsPrec _ (MVar n _ _ _) = ('?' :) . (T.unpack (alphanumber n) ++)
  showsPrec _ (Goal _ v) = ("(goal " ++) . shows v . (')':)

cons :: LispVal -> LispVal -> LispVal
cons l (List r) = List (l : r)
cons l (DottedList r0 rs r) = DottedList l (r0 : rs) r
cons l r = DottedList l [] r

isMVar :: LispVal -> Bool
isMVar (MVar _ _ _ _) = True
isMVar _ = False

isGoal :: LispVal -> Bool
isGoal (Goal _ _) = True
isGoal _ = False

sExprToLisp :: Offset -> SExpr -> LispVal
sExprToLisp o (SVar v) = Atom o v
sExprToLisp o (App t ts) = List (Atom o t : (sExprToLisp o <$> ts))

data ErrorLevel = ELError | ELWarning | ELInfo
instance Show ErrorLevel where
  show ELError = "error"
  show ELWarning = "warning"
  show ELInfo = "info"

data ElabError = ElabError {
  eeLevel :: ErrorLevel,
  eeRange :: Range,
  eeMsg :: Text,
  eeRelated :: [(Range, Text)] } deriving (Show)

toElabError :: ParseError -> ElabError
toElabError e = ElabError ELError (errorOffset e, errorOffset e)
  (T.pack (parseErrorTextPretty e)) []

-- This represents a hierarchical ordering of values:
-- 1 < 1.1 < 1.1.1 < 1.2 < 2 < 3
-- All sequence numbers are strictly positive.
data SeqNum = Simple Int | After Int SeqNum deriving (Eq)

instance Show SeqNum where
  showsPrec _ (Simple n) = shows n
  showsPrec _ (After n s) = shows n . ('.' :) . shows s

snUnfold :: SeqNum -> (Int, Maybe SeqNum)
snUnfold (Simple m) = (m, Nothing)
snUnfold (After m s) = (m, Just s)

snFold :: Int -> Maybe SeqNum -> SeqNum
snFold n = maybe (Simple n) (After n)

instance Ord SeqNum where
  compare (Simple m) (Simple n) = compare m n
  compare (Simple m) (After n _) = compare m n <> LT
  compare (After m _) (Simple n) = compare m n <> GT
  compare (After m s) (After n t) = compare m n <> compare s t

data SeqCounter = SeqCounter (I.IntMap SeqCounter) Int deriving (Show)

instance Default SeqCounter where
  def = SeqCounter def 1

incCounter :: Maybe SeqNum -> SeqCounter -> Maybe (Int, SeqCounter)
incCounter Nothing (SeqCounter c n) = Just (n, SeqCounter c (n+1))
incCounter (Just s) (SeqCounter c n) = do
  let (m, s') = snUnfold s
  (i, c'') <- case c I.!? m of
    Nothing -> return (1, def)
    Just c' -> incCounter s' c'
  return (i, SeqCounter (I.insert m c'' c) n)

data PLiteral = PConst Token | PVar Int Prec deriving (Show)

data PrefixInfo = PrefixInfo Range Token [PLiteral] deriving (Show)
data InfixInfo = InfixInfo Range Token Bool deriving (Show)
data Coe1 = Coe1 Range Sort
data Coe = Coe Coe1 | Coes Coe Sort Coe

foldCoe :: (Text -> a -> a) -> Coe -> a -> a
foldCoe tm (Coe (Coe1 _ t)) = tm t
foldCoe tm (Coes c1 _ c2) = foldCoe tm c1 . foldCoe tm c2

coeToList :: Coe -> Sort -> Sort -> [(Coe1, Sort, Sort)]
coeToList c' s1' s2' = go c' s1' s2' [] where
  go :: Coe -> Sort -> Sort -> [(Coe1, Sort, Sort)] -> [(Coe1, Sort, Sort)]
  go (Coe c) s1 s2 = ((c, s1, s2) :)
  go (Coes g s2 f) s1 s3 = go g s2 s3 . go f s1 s2

newtype Delims = Delims (U.Vector Word8)

instance Default Delims where
  def = Delims $ U.replicate 256 0 U.// [(fromEnum '\n', 4), (fromEnum ' ', 4)]

delimVal :: Delims -> Char -> Word8
delimVal (Delims v) c = U.unsafeIndex v (fromEnum (toEnum (fromEnum c) :: Word8))

isLeftDelim :: Word8 -> Bool
isLeftDelim w = testBit w 0

isRightDelim :: Word8 -> Bool
isRightDelim w = testBit w 1

data ParserEnv = ParserEnv {
  pDelims :: Delims,
  pPrefixes :: H.HashMap Token PrefixInfo,
  pInfixes :: H.HashMap Token InfixInfo,
  pPrec :: H.HashMap Token (Range, Prec),
  pCoes :: M.Map Sort (M.Map Sort Coe),
  pCoeProv :: H.HashMap Sort Sort }

instance Default ParserEnv where
  def = ParserEnv def H.empty H.empty H.empty def H.empty

data DeclNota = NPrefix Token | NInfix Token | NCoe Sort Sort

data Decl =
    DTerm [PBinder] DepType
  | DAxiom [PBinder] [SExpr] SExpr
  | DDef Visibility [PBinder] DepType (Maybe ([(Range, VarName, Sort)], SExpr))
  | DTheorem Visibility [PBinder] [SExpr] SExpr (ElabM Proof)

data LocalInfer = LIOld Binder (Maybe Sort) | LINew Range Bool Sort deriving (Show)

liOffset :: LocalInfer -> Range
liOffset (LIOld (Binder o _ _) _) = o
liOffset (LINew o _ _) = o

data InferCtx = InferCtx {
  icDependents :: H.HashMap VarName [Offset],
  icLocals :: H.HashMap VarName LocalInfer }

instance Default InferCtx where
  def = InferCtx H.empty H.empty

data ThmCtx = ThmCtx {
  tcVars :: H.HashMap VarName PBinder,
  tcProofs :: H.HashMap VarName Int,
  tcProofList :: VD.IOVector (VarName, LispVal, LispVal),
  tcMVars :: VD.IOVector (TVar LispVal),
  tcGoals :: V.Vector (TVar LispVal) }

data Env = Env {
  eTimeout :: Int,
  eLispData :: VD.IOVector LispVal,
  eLispNames :: H.HashMap Ident (Maybe (Range, Range), Int),
  eCounter :: SeqCounter,
  eSorts :: H.HashMap Sort (SeqNum, (Range, Range), SortData),
  eProvableSorts :: [Sort],
  eDecls :: H.HashMap Ident (SeqNum, (Range, Range), Decl, Maybe DeclNota),
  eParsedFmlas :: I.IntMap QExpr,
  ePE :: ParserEnv,
  eInfer :: InferCtx,
  eThmCtx :: Maybe ThmCtx }

instance Default Env where
  def = Env 5000000 undefined H.empty def H.empty def H.empty def def undefined def

data ElabFuncs = ElabFuncs {
  efMM0 :: Bool,
  efReport :: ElabError -> IO (),
  efAsync :: forall a. IO a -> IO (Async a) }
type Elab = RWST ElabFuncs () Env IO
type ElabM = MaybeT Elab

runElab :: Elab a -> Bool -> [ElabError] -> [(Ident, LispVal)] -> IO (a, [ElabError], Env)
runElab m mm0 errs lvs = do
  pErrs <- newTVarIO errs
  let report e = atomically $ modifyTVar pErrs (e :)
  dat <- VD.new 0
  let ins :: [(Ident, LispVal)] -> Int -> H.HashMap Ident (Maybe a, Int) ->
        IO (H.HashMap Ident (Maybe a, Int))
      ins [] _ hm = return hm
      ins ((x, v) : ls) n hm = VD.pushBack dat v >> ins ls (n+1) (H.insert x (Nothing, n) hm)
  hm <- ins lvs 0 H.empty
  caps <- getNumCapabilities
  withTaskGroup caps $ \g -> do
    let
      m' = m <* do
        decls <- gets (sortOn (\(s, _, _, _) -> s) . H.elems . eDecls)
        forM_ decls $ \case
          (_, _, DTheorem _ _ _ _ tm, _) -> () <$ runMaybeT tm
          _ -> return ()
    (a, env, _) <- runRWST m' (ElabFuncs mm0 report (async g))
      def {eLispData = dat, eLispNames = hm}
    errs' <- readTVarIO pErrs
    return (a, errs', env)

withTimeout :: Offset -> ElabM a -> ElabM a
withTimeout o m = MaybeT $ RWST $ \r s ->
  case eTimeout s of
    0 -> runRWST (runMaybeT m) r s
    n -> timeout n (runRWST (runMaybeT m) r s) >>= \case
      Just ret -> return ret
      Nothing -> runRWST (runMaybeT (escapeAt o $
        "timeout (use (set-timeout) to increase the timeout)")) r s

resuming :: ElabM () -> Elab ()
resuming m = () <$ runMaybeT m

reportErr :: ElabError -> ElabM ()
reportErr e = lift $ asks efReport >>= \f -> lift $ f e

ifMM0 :: ElabM () -> ElabM ()
ifMM0 m = asks efMM0 >>= \b -> when b m

escapeErr :: ElabError -> ElabM a
escapeErr e = reportErr e >> mzero

reportAt :: Offset -> ErrorLevel -> Text -> ElabM ()
reportAt o l s = reportErr $ ElabError l (o, o) s []

reportSpan :: Range -> ErrorLevel -> Text -> ElabM ()
reportSpan o l s = reportErr $ ElabError l o s []

escapeAt :: Offset -> Text -> ElabM a
escapeAt o s = reportAt o ELError s >> mzero

unimplementedAt :: Offset -> ElabM a
unimplementedAt pos = reportAt pos ELWarning "unimplemented" >> mzero

unwrap :: ElabM a -> Elab a
unwrap m = fromJust <$> runMaybeT m

fromJust' :: Maybe a -> ElabM a
fromJust' = MaybeT . return

fromJustAt :: Offset -> Text -> Maybe a -> ElabM a
fromJustAt _ _ (Just a) = return a
fromJustAt o msg Nothing = escapeAt o msg

guardAt :: Offset -> Text -> Bool -> ElabM ()
guardAt _ _ True = return ()
guardAt o msg False = escapeAt o msg

modifyPE :: (ParserEnv -> ParserEnv) -> Elab ()
modifyPE f = modify $ \env -> env {ePE = f (ePE env)}

after :: Maybe SeqNum -> ElabM SeqNum
after s = MaybeT $ state $ \env ->
  case incCounter s (eCounter env) of
    Nothing -> (Nothing, env)
    Just (n, c') -> (Just (snFold n s), env {eCounter = c'})

next :: ElabM SeqNum
next = after Nothing

now :: ElabM SeqNum
now = gets $ \env -> case eCounter env of SeqCounter _ n -> Simple n

try :: ElabM a -> ElabM (Maybe a)
try = lift . runMaybeT

forkElabM :: ElabM a -> ElabM (ElabM a)
forkElabM m = lift $ RWST $ \r s -> do
  a <- efAsync r $ fst <$> evalRWST (runMaybeT m) r s
  return (MaybeT $ lift $ wait a, s, ())

lispAlloc :: LispVal -> ElabM Int
lispAlloc v = do
  vec <- gets eLispData
  liftIO $ VD.length vec <* VD.pushBack vec v

lispLookupNum :: Int -> ElabM LispVal
lispLookupNum n = do
  vec <- gets eLispData
  liftIO $ VD.read vec n

lispLookupName :: T.Text -> ElabM LispVal
lispLookupName v = gets (H.lookup v . eLispNames) >>= \case
  Nothing -> mzero
  Just (_, n) -> lispLookupNum n

lispDefine :: Range -> Range -> T.Text -> LispVal -> ElabM ()
lispDefine rd rx x v = do
  n <- lispAlloc v
  modify $ \env -> env {eLispNames = H.insert x (Just (rd, rx), n) (eLispNames env)}

newRef :: a -> ElabM (TVar a)
newRef = liftIO . newTVarIO

getRef :: TVar a -> ElabM a
getRef = liftIO . readTVarIO

setRef :: TVar a -> a -> ElabM ()
setRef x v = liftIO $ atomically $ writeTVar x v

getSort :: Text -> SeqNum -> ElabM ((Range, Range), SortData)
getSort v s =
  gets (H.lookup v . eSorts) >>= \case
    Just (n, o, sd) -> guard (n < s) >> return (o, sd)
    _ -> mzero

lookupTerm :: Text -> Env -> Maybe (SeqNum, (Range, Range), [PBinder], DepType, Maybe DeclNota)
lookupTerm v env = H.lookup v (eDecls env) >>= \case
    (n, o, DTerm args r, no) -> Just (n, o, args, r, no)
    (n, o, DDef _ args r _, no) -> Just (n, o, args, r, no)
    _ -> Nothing

getTerm :: Text -> SeqNum -> ElabM ((Range, Range), [PBinder], DepType, Maybe DeclNota)
getTerm v s = gets (lookupTerm v) >>= \case
  Just (n, o, args, r, no) -> guard (n < s) >> return (o, args, r, no)
  _ -> mzero

lookupThm :: Text -> Env -> Maybe (SeqNum, (Range, Range), [PBinder], [SExpr], SExpr)
lookupThm v env = H.lookup v (eDecls env) >>= \case
  (n, o, DAxiom args hyps r, _) -> Just (n, o, args, hyps, r)
  (n, o, DTheorem _ args hyps r _, _) -> Just (n, o, args, hyps, r)
  _ -> Nothing

getThm :: Text -> SeqNum -> ElabM ((Range, Range), [PBinder], [SExpr], SExpr)
getThm v s = gets (lookupThm v) >>= \case
    Just (n, o, args, hyps, r) -> guard (n < s) >> return (o, args, hyps, r)
    _ -> mzero

getDeclNotaOffset :: DeclNota -> ElabM Range
getDeclNotaOffset (NPrefix tk) =
  gets ((\(PrefixInfo o _ _) -> o) . (H.! tk) . pPrefixes . ePE)
getDeclNotaOffset (NInfix tk) =
  gets ((\(InfixInfo o _ _) -> o) . (H.! tk) . pInfixes . ePE)
getDeclNotaOffset (NCoe s1 s2) =
  gets ((M.! s2) . (M.! s1) . pCoes . ePE) >>= \case
    Coe (Coe1 o _) -> return o
    _ -> mzero

modifyInfer :: (InferCtx -> InferCtx) -> ElabM ()
modifyInfer f = modify $ \env -> env {eInfer = f (eInfer env)}

modifyTC :: (ThmCtx -> ThmCtx) -> ElabM ()
modifyTC f = modify $ \env -> env {eThmCtx = f <$> eThmCtx env}

withInfer :: ElabM a -> ElabM a
withInfer m = modifyInfer (const def) *> m <* modifyInfer (const undefined)

withTC :: H.HashMap VarName PBinder -> ElabM a -> ElabM a
withTC vs m = do
  pv <- liftIO $ VD.new 0
  mv <- liftIO $ VD.new 0
  modify $ \env -> env {eThmCtx = Just $ ThmCtx vs H.empty pv mv V.empty}
  m <* modify (\env -> env {eThmCtx = def})

getTC :: ElabM ThmCtx
getTC = MaybeT $ gets eThmCtx

newMVar :: Offset -> Sort -> Bool -> ElabM (TVar LispVal)
newMVar o s bd = do
  mv <- tcMVars <$> getTC
  n <- VD.length mv
  v <- newRef (MVar n o s bd)
  liftIO $ VD.pushBack mv v
  return v

newUnknownMVar :: Offset -> ElabM (TVar LispVal)
newUnknownMVar o = newMVar o "" False

modifyMVars :: (V.Vector (TVar LispVal) -> ElabM (V.Vector (TVar LispVal))) -> ElabM ()
modifyMVars f = do
  v1 <- getTC >>= liftIO . VD.unsafeFreeze . tcMVars
  mv2 <- f v1 >>= liftIO . VD.unsafeThaw
  modifyTC $ \tc -> tc {tcMVars = mv2}

cleanMVars :: ElabM ()
cleanMVars = modifyMVars $ \vec -> do
  vec' <- V.filterM (fmap isMVar . getRef) vec
  V.imapM_ (\n g ->
    let go (MVar _ o s bd) = MVar n o s bd
        go e = e
    in liftIO $ atomically $ modifyTVar g go) vec'
  return vec'

addSubproof :: VarName -> LispVal -> LispVal -> ElabM ()
addSubproof h t p = do
  pv <- tcProofList <$> getTC
  n <- VD.length pv
  liftIO $ VD.pushBack pv (h, t, p)
  modifyTC $ \tc -> tc {tcProofs = H.insert h n (tcProofs tc)}

getSubproof :: VarName -> ElabM LispVal
getSubproof h = do
  tc <- getTC
  (_, e, _) <- fromJust' (H.lookup h (tcProofs tc)) >>= VD.read (tcProofList tc)
  return e

setGoals :: [TVar LispVal] -> ElabM ()
setGoals gs = do
  gs' <- filterM (fmap isGoal . getRef) gs
  modifyTC $ \tc -> tc {tcGoals = V.fromList gs'}

peGetCoe' :: ParserEnv -> Text -> Text -> Maybe Coe
peGetCoe' pe s1 s2 = M.lookup s1 (pCoes pe) >>= M.lookup s2

getCoe' :: Text -> Text -> ElabM Coe
getCoe' s1 s2 = gets ePE >>= \pe -> fromJust' $ peGetCoe' pe s1 s2

peGetCoe :: ParserEnv -> (Text -> a -> a) -> Text -> Text -> Maybe (a -> a)
peGetCoe _ _ s1 s2 | s1 == s2 = return id
peGetCoe pe tm s1 s2 = foldCoe tm <$> peGetCoe' pe s1 s2

getCoe :: (Text -> a -> a) -> Text -> Text -> ElabM (a -> a)
getCoe tm s1 s2 = gets ePE >>= \pe -> fromJust' $ peGetCoe pe tm s1 s2

peGetCoeProv :: ParserEnv -> (Text -> a -> a) -> Text -> Maybe (Text, a -> a)
peGetCoeProv pe tm s = do
  s2 <- H.lookup s (pCoeProv pe)
  c <- peGetCoe pe tm s s2
  return (s2, c)

getCoeProv :: (Text -> a -> a) -> Text -> ElabM (Text, a -> a)
getCoeProv tm s = gets ePE >>= \pe -> fromJust' $ peGetCoeProv pe tm s

addCoe :: Coe1 -> Sort -> Sort -> ElabM ()
addCoe cc@(Coe1 o _) = \s1 s2 -> do
  let cs = Coe cc
  coes1 <- gets (pCoes . ePE)
  coes2 <- foldCoeLeft s1 coes1 (\s1' l r -> r >>= addCoeInner (Coes cs s1' l) s1' s2) (return coes1)
  coes3 <- addCoeInner cs s1 s2 coes2
  coes4 <- foldCoeRight s2 coes3 (\s2' l r -> r >>= addCoeInner (Coes l s2' cs) s1 s2') (return coes3)
  setCoes coes4
  where

  foldCoeLeft :: Sort -> M.Map Sort (M.Map Sort Coe) -> (Sort -> Coe -> a -> a) -> a -> a
  foldCoeLeft s2 coes f a' = M.foldrWithKey' g a' coes where
    g s1 m a = maybe a (\l -> f s1 l a) (M.lookup s2 m)

  foldCoeRight :: Sort -> M.Map Sort (M.Map Sort Coe) -> (Sort -> Coe -> a -> a) -> a -> a
  foldCoeRight s1 coes f a = maybe a (M.foldrWithKey' f a) (M.lookup s1 coes)

  toStrs :: [(Coe1, Sort, Sort)] -> [Text]
  toStrs [] = undefined
  toStrs [(_, s1, s2)] = [s1, " -> ", s2]
  toStrs ((_, s1, _) : cs) = s1 : " -> " : toStrs cs

  toRelated :: [(Coe1, Sort, Sort)] -> [(Range, Text)]
  toRelated = fmap $ \(Coe1 o' _, s1, s2) -> (o', s1 <> " -> " <> s2)

  addCoeInner :: Coe -> Sort -> Sort ->
    M.Map Sort (M.Map Sort Coe) -> ElabM (M.Map Sort (M.Map Sort Coe))
  addCoeInner c s1 s2 coes = do
    let l = coeToList c s1 s2
    when (s1 == s2) $ do
      escapeErr $ ElabError ELError o
        (T.concat ("coercion cycle detected: " : toStrs l))
        (toRelated l)
    try (getCoe' s1 s2) >>= mapM_ (\c2 -> do
      let l2 = coeToList c2 s1 s2
      escapeErr $ ElabError ELError o
        (T.concat ("coercion diamond detected: " : toStrs l ++ ";   " : toStrs l2))
        (toRelated (l ++ l2)))
    return $ M.alter (Just . M.insert s2 c . maybe M.empty id) s1 coes

  setCoes :: M.Map Sort (M.Map Sort Coe) -> ElabM ()
  setCoes coes = do
    sorts <- gets eSorts
    let provs = H.keysSet (H.filter (\(_, _, sd) -> sProvable sd) sorts)
        f :: Sort -> Sort -> Coe -> ElabM (H.HashMap Sort Sort) -> ElabM (H.HashMap Sort Sort)
        f s1 s2' c' r =
          if HS.member s2' provs then do
            m <- r
            forM_ (H.lookup s1 m) $ \s2 -> do
              c <- getCoe' s1 s2
              let l = coeToList c s1 s2
              let l' = coeToList c' s1 s2'
              escapeErr $ ElabError ELError o
                (T.concat ("coercion diamond to provable detected:\n" :
                  toStrs l ++ " provable\n" : toStrs l' ++ [" provable"]))
                (toRelated (l ++ l'))
            return (H.insert s1 s2' m)
          else r
    m <- M.foldrWithKey' (\s1' m r -> M.foldrWithKey' (f s1') r m)
      (return (foldr (\v -> H.insert v v) H.empty provs)) coes
    lift $ modifyPE $ \pe -> pe {pCoes = coes, pCoeProv = m}
