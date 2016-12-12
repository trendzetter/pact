{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module Pact.Typecheck where

import Pact.Repl
import Pact.Types
import Control.Monad.Catch
import Control.Lens hiding (pre,List)
import Bound.Scope
import Safe hiding (at)
import Data.Default
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Data.List.NonEmpty (NonEmpty (..))
import Control.Arrow hiding ((<+>))
import Data.Aeson hiding (Object, (.=))
import Data.Foldable
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import Data.String
import Data.Maybe
import Data.List
import qualified Text.PrettyPrint.ANSI.Leijen as PP

data CheckerException = CheckerException Info String deriving (Eq,Ord)

instance Exception CheckerException
instance Show CheckerException where show (CheckerException i s) = renderInfo i ++ ": " ++ s

die :: MonadThrow m => Info -> String -> m a
die i s = throwM $ CheckerException i s

data VarRole = ArgVar Int | RetVar deriving (Eq,Show,Ord)

data VarType = Spec { _vtType :: Type } |
               Overload { _vtRole :: VarRole, _vtOverApp :: TcId }
               deriving (Eq,Ord)

type TypeSet = S.Set VarType
newtype TypeSetId = TypeSetId String
  deriving (Eq,Ord,IsString,AsString)
instance Show TypeSetId where show (TypeSetId i) = show i

data SolverEdge = SolverEdge {
  _seTypeSet :: TypeSetId,
  _seVarRole :: VarRole,
  _seOverload :: TcId
  } deriving (Eq,Show,Ord)

instance Show VarType where
  show (Spec t) = show t
  show (Overload r ts) =
    show ts ++ "?" ++ (case r of ArgVar i -> show i; RetVar -> "r")

instance Pretty VarType where pretty = string . show

type Pivot = M.Map VarType TypeSet

data TcState = TcState {
  _tcSupply :: Int,
  _tcVars :: M.Map TcId TypeSet,
  _tcOverloads :: M.Map TcId FunTypes,
  _tcPivot :: Pivot,
  _tcFailures :: S.Set CheckerException
  } deriving (Eq,Show)


instance Default TcState where def = TcState 0 def def def def
instance Pretty TcState where
  pretty TcState {..} = string "Vars:" PP.<$>
    indent 2 (vsep $ map (\(k,v) -> pretty k <+> colon <+> string (show v)) $ M.toList $ M.map S.toList _tcVars) PP.<$>
    string "Overloads:" PP.<$>
    indent 2 (vsep $ map (\(k,v) -> pretty k <> string "?" <+> colon <+>
                           align (vsep (map (string . show) (toList v)))) $ M.toList _tcOverloads) PP.<$>
    prettyPivot _tcPivot PP.<$>
    string "Failures:" PP.<$> indent 2 (hsep $ map (string.show) (toList _tcFailures))
    <> hardline

prettyPivot :: M.Map VarType TypeSet -> Doc
prettyPivot p =
  string "Pivot:" PP.<$>
  indent 2 (vsep $ map (\(k,v) -> pretty k  <+> colon PP.<$>
                         indent 4 (hsep (map (string . show) (toList v)))) $ M.toList p) PP.<$>
  string "Sets:" PP.<$>
  indent 2 (vsep (map (\v -> hsep (map (string . show) (toList v))) $ nub (M.elems p)))



newtype TC a = TC { unTC :: StateT TcState IO a }
  deriving (Functor,Applicative,Monad,MonadState TcState,MonadIO,MonadThrow,MonadCatch)


data TcId = TcId {
  _tiInfo :: Info,
  _tiName :: String,
  _tiId :: Int
  }

instance Eq TcId where
  a == b = _tiId a == _tiId b && _tiName a == _tiName b
instance Ord TcId where
  a <= b = _tiId a < _tiId b || (_tiId a == _tiId b && _tiName a <= _tiName b)
-- show instance is important, used as variable name
instance Show TcId where show TcId {..} = _tiName ++ show _tiId
instance Pretty TcId where pretty = string . show

makeLenses ''TcState
makeLenses ''VarType



freshId :: Info -> String -> TC TcId
freshId i n = TcId i n <$> state (_tcSupply &&& over tcSupply succ)

data LitValue =
  LVLit Literal |
  LVKeySet PactKeySet |
  LVValue Value
  deriving (Eq,Show)
instance Pretty LitValue where
  pretty (LVLit l) = text (show l)
  pretty (LVKeySet k) = text (show k)
  pretty (LVValue v) = text (show v)

data Fun t =
  FNative {
    _fInfo :: Info,
    _fName :: String,
    _fTypes :: FunTypes } |
  FDefun {
    _fInfo :: Info,
    _fName :: String,
    _fType :: FunType,
    _fArgs :: [t],
    _fBody :: [AST t] }
  deriving (Eq,Functor,Foldable,Show)

instance Pretty t => Pretty (Fun t) where
  pretty FNative {..} = text ("Native: " ++ show _fName) PP.<$>
    indent 2 (vsep (map (text.show) (toList _fTypes)))
  pretty FDefun {..} = text ("Defun: " ++ show _fName) <+> text (show _fType) PP.<$>
    sep (map pretty _fArgs) PP.<$>
    vsep (map pretty _fBody)



data AST t =
  App {
  _aId :: TcId,
  _aAppFun :: Fun t,
  _aAppArgs :: [AST t]
  } |
  Binding {
  _aId :: TcId,
  _aBindings :: [(t,AST t)],
  _aBody :: [AST t],
  _aBindCtx :: BindCtx
  } |
  List {
  _aId :: TcId,
  _aList :: [AST t],
  _aListType :: Maybe Type
  } |
  Object {
  _aId :: TcId,
  _aObject :: [(AST t,AST t)],
  _aUserType :: Maybe TypeName
  } |
  Lit {
  _aId :: TcId,
  _aLitType :: Type,
  _aLitValue :: LitValue
  } |
  Var {
  _aId :: TcId,
  _aVar :: t }
  deriving (Eq,Functor,Foldable,Show)

instance Pretty t => Pretty (AST t) where
  pretty Lit {..} = pretty _aLitType
  pretty Var {..} = pretty _aVar
  pretty Object {..} = "{" <+> align (sep (map (\(k,v) -> pretty k <> text ":" <+> pretty v) _aObject)) <+> "}"
  pretty List {..} = list (map pretty _aList)
  pretty Binding {..} =
    pretty _aId PP.<$>
    indent 2 (vsep (map (\(k,v) -> pretty k <> text ":" PP.<$> indent 4 (pretty v)) _aBindings)) PP.<$>
    indent 4 (vsep (map pretty _aBody))
  pretty App {..} =
    pretty _aId <+> text (_fName _aAppFun) PP.<$>
    indent 4 (case _aAppFun of
       FNative {..} -> vsep (map (text . show) (toList _fTypes))
       FDefun {..} -> text (show _fType)) PP.<$>
    (case _aAppFun of
        FNative {} -> (<> empty)
        FDefun {..} -> (PP.<$> indent 4 (vsep (map pretty _fBody))))
    (indent 2 (vsep (map pretty _aAppArgs)))



makeLenses ''AST
makeLenses ''Fun

runTC :: TC a -> IO (a, TcState)
runTC a = runStateT (unTC a) def

data Visit = Pre | Post deriving (Eq,Show)
type Visitor n = Visit -> AST n -> TC (AST n)

-- | Walk the AST, performing function both before and after descent into child elements.
walkAST :: Visitor n -> AST n -> TC (AST n)
walkAST f t@Lit {} = f Pre t >>= f Post
walkAST f t@Var {} = f Pre t >>= f Post
walkAST f t@Object {} = do
  Object {..} <- f Pre t
  t' <- Object _aId <$>
         forM _aObject (\(k,v) -> (,) <$> walkAST f k <*> walkAST f v) <*>
         pure _aUserType
  f Post t'
walkAST f t@List {} = do
  List {..} <- f Pre t
  t' <- List _aId <$> mapM (walkAST f) _aList <*> pure _aListType
  f Post t'
walkAST f t@Binding {} = do
  Binding {..} <- f Pre t
  t' <- Binding _aId <$>
        forM _aBindings (\(k,v) -> (k,) <$> walkAST f v) <*>
        mapM (walkAST f) _aBody <*> pure _aBindCtx
  f Post t'
walkAST f t@App {} = do
  App {..} <- f Pre t
  t' <- App _aId <$>
        (case _aAppFun of fun@FNative {} -> return fun
                          fun@FDefun {..} -> do
                             db <- mapM (walkAST f) _fBody
                             return $ set fBody db fun) <*>
        mapM (walkAST f) _aAppArgs
  f Post t'

isOverload :: VarType -> Bool
isOverload Overload {} = True
isOverload _ = False

isConcrete :: VarType -> Bool
isConcrete (Spec ty) = case ty of
  TyVar {} -> False
  TyRest -> False
  TyFun {} -> False
  _ -> True
isConcrete _ = False

isRestOrUnconstrained :: VarType -> Bool
isRestOrUnconstrained (Spec ty) = case ty of
  TyVar _ [] -> True
  TyRest -> True
  _ -> False
isRestOrUnconstrained _ = False

isTyVar :: VarType -> Bool
isTyVar (Spec TyVar {}) = True
isTyVar _ = False

-- | take vars map of thing->{typevars} to
-- typevar->{typevars}, where for each typevar, build the
-- set of all types that refer to it, such that each of those
-- types are in turn indexed to this same set.
pivot :: TC ()
pivot = do
  m <- use tcVars
  tcPivot .= pivot' m

pivot' :: M.Map a TypeSet -> Pivot
pivot' m = rpt initPivot
  where
    initPivot = execState (rinse m) M.empty
    lather = execState (get >>= rinse)
    rinse :: M.Map a TypeSet -> State (M.Map VarType TypeSet) ()
    rinse p =
      forM_ (M.elems p) $ \vts ->
        forM_ vts $ \vt ->
          when (isTyVar vt || isOverload vt) $ modify $ M.insertWith S.union vt vts
    rpt p = let p' = lather p in if p' == p then p else rpt p'


failEx :: a -> TC a -> TC a
failEx a = handle (\(e :: CheckerException) -> tcFailures %= S.insert e >> return a)


eliminate :: TC ()
eliminate = do
  vsets <- S.fromList . M.elems <$> use tcPivot
  forM_ vsets $ \vset -> do
    final <- typecheckSet def vset
    tcPivot %= M.map (\s -> if s == vset then final else s)

eliminate' :: MonadThrow m => Pivot -> m Pivot
eliminate' p = (`execStateT` p) $ do
  let vsets = S.fromList $ M.elems p
  forM_ vsets $ \vset -> do
    final <- typecheckSet' def vset
    modify $ M.map (\s -> if s == vset then final else s)



-- | Typechecks set and eliminates matched type vars.
typecheckSet :: Info -> TypeSet -> TC TypeSet
typecheckSet inf vset = failEx vset $ typecheckSet' inf vset

typecheckSet' :: MonadThrow m => Info -> TypeSet -> m TypeSet
typecheckSet' inf vset = do
  let (_rocs,v1) = S.partition isRestOrUnconstrained vset
      (concs,v2) = S.partition isConcrete v1
  conc <- case toList concs of
    [] -> return Nothing
    [c] -> return $ Just c
    _cs -> die inf $ "Multiple concrete types in set:" ++ show vset
  let (tvs,rest) = S.partition isTyVar v2
      constraintsHaveType c t = case t of
        (Spec (TyVar _ es)) -> c `elem` es
        _ -> False
  case conc of
    Just c@(Spec concTy) -> do
      unless (all (constraintsHaveType concTy) tvs) $
        die inf $ "Constraints incompatible with concrete type: " ++ show vset
      return $ S.insert c rest -- constraints good with concrete, so we can get rid of them
    Just c -> die inf $ "Internal error, expected concrete type: " ++ show c
    Nothing ->
      if S.null tvs then return rest -- no conc, no tvs, just leftovers
      else do
        let inter = S.toList $ foldr1 S.intersection $ map S.fromList $ mapMaybe (firstOf (vtType.tvConstraint)) (toList tvs)
        case inter of
          [] -> die inf $ "Incommensurate constraints in set: " ++ show vset
          _ -> do
            let uname = foldr1 (\a b -> a ++ "_U_" ++ b) $ mapMaybe (firstOf (vtType.tvId)) (toList tvs)
            return $ S.insert (Spec (TyVar uname inter)) rest

data SolverState = SolverState {
  _funMap :: M.Map TcId (FunTypes,M.Map VarRole Type,Maybe FunType),
  _tsetMap :: M.Map TypeSetId (TypeSet,Maybe Type)
} deriving (Eq,Show)
makeLenses ''SolverState
data SolverEnv = SolverEnv {
  _graph :: M.Map (Either TypeSetId TcId) [SolverEdge]
  }
makeLenses ''SolverEnv

type Solver = StateT SolverState (ReaderT SolverEnv IO)

runSolver :: SolverState -> SolverEnv -> Solver a -> IO (a, SolverState)
runSolver s e a = runReaderT (runStateT a s) e

buildSolverGraph :: TC ()
buildSolverGraph = do
  tss <- nub . M.elems <$> use tcPivot
  (oMap :: M.Map TcId (FunTypes,M.Map VarRole Type,Maybe FunType)) <- M.map (,def,Nothing) <$> use tcOverloads
  (stuff :: [((TypeSetId,(TypeSet,Maybe Type)),[SolverEdge])]) <- fmap catMaybes $ forM tss $ \ts -> do
    let tid = TypeSetId (show (toList ts))
        es = (`map` toList ts) $ \v -> case v of
               Overload r i -> Right (SolverEdge tid r i)
               Spec t | isConcrete v -> Left (Just t)
               _ -> Left Nothing
    concrete <- case (`mapMaybe` es) (either id (const Nothing)) of
      [] -> return Nothing
      [a] -> return (Just a)
      _ -> die def $ "Internal error: more than one concrete type in set: " ++ show ts
    let ses = mapMaybe (either (const Nothing) Just) es
    if null ses then return Nothing else
      return $ Just ((tid,(ts,concrete)),mapMaybe (either (const Nothing) Just) es)
  let tsMap :: M.Map TypeSetId (TypeSet,Maybe Type)
      tsMap = M.fromList $ map fst stuff
      initState = SolverState oMap tsMap
      concretes :: [TypeSetId]
      concretes = (`mapMaybe` stuff) $ \((tid,(_,t)),_) -> tid <$ t
      edges :: [SolverEdge]
      edges = concatMap snd stuff
      edgeMap :: M.Map (Either TypeSetId TcId) [SolverEdge]
      edgeMap = M.fromListWith (++) $ (`concatMap` edges) $ \s@(SolverEdge t _ i) -> [(Left t,[s]),(Right i,[s])]

  let
      doFuns :: [TcId] -> Solver [TypeSetId]
      doFuns ovs = fmap concat $ forM ovs $ \ov -> do
        fr <- M.lookup ov <$> use funMap
        er <- M.lookup (Right ov) <$> view graph
        case (fr,er) of
          (Just (fTys,mems,Nothing),Just es) -> undefined


  r <- liftIO $ runSolver initState (SolverEnv edgeMap) $ subArgs concretes
  liftIO $ print r

subArgs :: [TypeSetId] -> Solver [TcId]
subArgs cs = fmap (nub . concat) $ forM cs $ \c -> do
  cr <- M.lookup c <$> use tsetMap
  er <- M.lookup (Left c) <$> view graph
  case (cr,er) of
    (Just (_, Just ct),Just es) -> forM es $ \(SolverEdge _ r ov) -> do
      funMap %= M.adjust (over _2 (M.insert r ct)) ov
      return ov
    (_,_) -> return []

tryFunType :: MonadCatch m => FunType -> M.Map VarRole Type -> m (Maybe (M.Map VarRole Type))
tryFunType (FunType as rt) vMap = do
  let ars = zipWith (\(Arg _ t _) i -> (ArgVar i,t)) as [0..]
      fMap = M.fromList $ (RetVar,rt):ars
      toSets = M.map (S.singleton . Spec)
      setsMap = M.unionWith S.union (toSets vMap) (toSets fMap)
      piv = pivot' setsMap
  handle (\(_ :: CheckerException) -> return Nothing) $ do
    elim <- eliminate' piv
    let remapped :: M.Map VarRole TypeSet
        remapped = (`M.map` setsMap) $ \s -> mconcat $ (`map` toList s) $ \t ->
          if isTyVar t then fromMaybe S.empty $ M.lookup t elim
          else S.singleton t
        justConcs = (`map` M.toList remapped) $ \(vr,s) ->
          if S.size s == 1 then
            let h = head (toList s) in
              if isConcrete h then Just (vr,_vtType h) else Nothing
          else Nothing
    case sequence justConcs of
      Nothing -> return Nothing
      Just ps -> return (Just (M.fromList ps))

_ftaaa :: FunType
_ftaaa = let a = TyVar "a" [TyInteger,TyDecimal]
         in FunType [Arg "x" a def,Arg "y" a def] a
_ftabD :: FunType
_ftabD = let v n = TyVar n [TyInteger,TyDecimal]
         in FunType [Arg "x" (v "a") def,Arg "y" (v "b") def] TyDecimal

{-

λ> tryFunType _ftaaa (M.fromList [(ArgVar 0,TyDecimal),(ArgVar 1,TyInteger)])
Nothing
λ> tryFunType _ftaaa (M.fromList [(ArgVar 0,TyDecimal),(ArgVar 1,TyDecimal)])
Just (fromList [(ArgVar 0,decimal),(ArgVar 1,decimal),(RetVar,decimal)])
λ> tryFunType _ftabD (M.fromList [(ArgVar 0,TyDecimal),(ArgVar 1,TyInteger)])
Just (fromList [(ArgVar 0,decimal),(ArgVar 1,integer),(RetVar,decimal)])
λ> tryFunType _ftabD (M.fromList [(ArgVar 0,TyDecimal)])
Nothing
λ>

-}



processNatives :: Visitor TcId
processNatives Pre a@(App i FNative {..} as) = do
  case _fTypes of
    -- single funtype
    ft@FunType {} :| [] -> do
      let FunType {..} = mangleFunType i ft
      zipWithM_ (\(Arg _ t _) aa -> assocTy (_aId aa) (Spec t)) _ftArgs as
      assocTy i (Spec _ftReturn)
    -- multiple funtypes
    fts -> do
      let fts' = fmap (mangleFunType i) fts
      tcOverloads %= M.insert i fts'
      zipWithM_ (\ai aa -> assocTy (_aId aa) (Overload (ArgVar ai) i)) [0..] as
      assocTy i (Overload RetVar i)
  return a
processNatives _ a = return a

-- | substitute app args into vars for FDefuns
substAppDefun :: Maybe (TcId, AST TcId) -> Visitor TcId
substAppDefun nr Pre t@Var {..} = case nr of
    Nothing -> return t
    Just (n,r) | n == _aVar -> assocAST n r >> return r -- might need a typecheck here
               | otherwise -> return t
substAppDefun _ Post App {..} = do -- Post, to allow args to get substituted out first.
    af <- case _aAppFun of
      f@FNative {} -> return f
      f@FDefun {..} -> do
        fb' <- forM _fBody $ \bt ->
          foldM (\b fa -> walkAST (substAppDefun (Just fa)) b) bt (zip _fArgs _aAppArgs) -- this zip might need a typecheck
        return $ set fBody fb' f
    return (App _aId af _aAppArgs)
substAppDefun _ _ t = return t

lookupIdTys :: TcId -> TC (TypeSet)
lookupIdTys i = (fromMaybe S.empty . M.lookup i) <$> use tcVars



tcToTy :: AST TcId -> TC (TypeSet)
tcToTy Lit {..} = return $ S.singleton $ Spec _aLitType
tcToTy Var {..} = lookupIdTys _aVar
tcToTy Object {..} = return $ S.singleton $ Spec $ TyObject _aUserType
tcToTy List {..} = return $ S.singleton $ Spec $ TyList _aListType
tcToTy App {..} = lookupIdTys _aId
tcToTy Binding {..} = lookupIdTys _aId

-- | Track type to id
trackVar :: TcId -> VarType -> TC ()
trackVar i t = do
  old <- M.lookup i <$> use tcVars
  case old of
    Nothing -> return ()
    Just tys -> die (_tiInfo i) $ "Internal error: type already tracked: " ++ show (i,t,tys)
  tcVars %= M.insert i (S.singleton t)

-- | Track type to id with typechecking
assocTy :: TcId -> VarType -> TC ()
assocTy i ty = assocTys i (S.singleton ty)

-- | Track ast type to id with typechecking
assocAST :: TcId -> AST TcId -> TC ()
assocAST i a = tcToTy a >>= assocTys i

-- | Track types to id with typechecking
-- TODO figure out better error messages. The type being added
-- is at least in App case the specified type to the arg type,
-- meaning the already-tracked type is the unexpected one.
assocTys :: TcId -> TypeSet -> TC ()
assocTys i tys = do
  tys' <- S.union tys <$> lookupIdTys i
  void $ typecheckSet (_tiInfo i) tys'
  tcVars %= M.insert i tys'

scopeToBody :: Info -> [AST TcId] -> Scope Int Term (Either Ref (AST TcId)) -> TC [AST TcId]
scopeToBody i args bod = do
  bt <- instantiate (return . Right) <$> traverseScope (bindArgs i args) return bod
  case bt of
    (TList ts@(_:_) _ _) -> mapM toAST ts -- verifies non-empty body.
    _ -> die i "Malformed def body"

pfx :: String -> String -> String
pfx s = ((s ++ "_") ++)

idTyVar :: TcId -> Type
idTyVar i = TyVar (show i) []

mangleType :: TcId -> Type -> Type
mangleType f t@TyVar {} = over tvId (pfx (show f)) t
mangleType f t@TyList {} = over (tlType . _Just) (mangleType f) t
mangleType f t@TyFun {} = over tfType (mangleFunType f) t
mangleType _ t = t

mangleFunType :: TcId -> FunType -> FunType
mangleFunType f = over ftReturn (mangleType f) .
                  over (ftArgs.traverse.aType) (mangleType f)


toFun :: Term (Either Ref (AST TcId)) -> TC (Fun TcId)
toFun (TVar (Left (Direct (TNative DefData {..} _ i))) _) = return $ FNative i _dName _dType
toFun (TVar (Left (Ref r)) _) = toFun (fmap Left r)
toFun (TVar Right {} i) = die i "Value in fun position"
toFun (TDef DefData {..} bod _ i) = do -- TODO currently creating new vars every time, is this ideal?
  ty <- case _dType of
    t :| [] -> return t
    _ -> die i "Multiple def types not allowed"
  let fn = maybe _dName ((++ ('.':_dName)) . asString) _dModule
  args <- forM (_ftArgs ty) $ \(Arg n t ai) -> do
    an <- freshId ai $ pfx fn n
    let t' = mangleType an t
    trackVar an (Spec t')
    return an
  tcs <- scopeToBody i (map (\ai -> Var ai ai) args) bod
  return $ FDefun i fn ty args tcs
toFun t = die (_tInfo t) "Non-var in fun position"


toAST :: Term (Either Ref (AST TcId)) -> TC (AST TcId)
toAST TNative {..} = die _tInfo "Native in value position"
toAST TDef {..} = die _tInfo "Def in value position"
toAST (TVar v i) = case v of -- value position only, TApp has its own resolver
  (Left (Ref r)) -> toAST (fmap Left r)
  (Left Direct {}) -> die i "Native in value context"
  (Right t) -> return t
toAST TApp {..} = do
  fun <- toFun _tAppFun
  i <- freshId _tInfo $
       "app" ++ (case fun of FDefun {} -> "D"; _ -> "N") ++  _fName fun
  trackVar i (Spec $ idTyVar i)
  as <- mapM toAST _tAppArgs
  case fun of
    FDefun {..} -> assocAST i (last _fBody)
    FNative {} -> return ()
  return $ App i fun as

toAST TBinding {..} = do
  bi <- freshId _tInfo (case _tBindCtx of BindLet -> "let"; BindKV -> "bind")
  trackVar bi $ Spec $ case _tBindCtx of BindLet -> idTyVar bi; BindKV -> TyObject Nothing
  bs <- forM _tBindPairs $ \(Arg n t ai,v) -> do
    an <- freshId ai (pfx (show bi) n)
    let t' = mangleType an t
    trackVar an $ Spec t'
    v' <- toAST v
    assocAST an v'
    return (an,v')
  bb <- scopeToBody _tInfo (map ((\ai -> Var ai ai).fst) bs) _tBindBody
  assocAST bi (last bb)
  return $ Binding bi bs bb _tBindCtx

toAST TList {..} = List <$> freshId _tInfo "list" <*> mapM toAST _tList <*> pure _tListType
toAST TObject {..} = Object <$> freshId _tInfo "object" <*>
                       mapM (\(k,v) -> (,) <$> toAST k <*> toAST v) _tObject <*> pure _tUserType
toAST TConst {..} = toAST _tConstVal -- TODO typecheck here
toAST TKeySet {..} = freshId _tInfo "keyset" >>= \i -> return $ Lit i TyKeySet (LVKeySet _tKeySet)
toAST TValue {..} = freshId _tInfo "value" >>= \i -> return $ Lit i TyValue (LVValue _tValue)
toAST TLiteral {..} = do
  let ty = l2ty _tLiteral
  i <- freshId _tInfo (show ty)
  trackVar i (Spec ty)
  return $ Lit i ty (LVLit _tLiteral)
toAST TModule {..} = die _tInfo "Modules not supported"
toAST TUse {..} = die _tInfo "Use not supported"
toAST TStep {..} = die _tInfo "TODO steps/pacts"

l2ty :: Literal -> Type
l2ty LInteger {} = TyInteger
l2ty LDecimal {} = TyDecimal
l2ty LString {} = TyString
l2ty LBool {} = TyBool
l2ty LTime {} = TyTime

bindArgs :: Info -> [a] -> Int -> TC a
bindArgs i args b =
  case args `atMay` b of
    Nothing -> die i $ "Missing arg: " ++ show b ++ ", " ++ show (length args) ++ " provided"
    Just a -> return a


infer :: Term Ref -> TC (Fun TcId)
infer t@TDef {..} = toFun (fmap Left t)
infer t = die (_tInfo t) "Non-def"


substFun :: Fun TcId -> TC (Fun TcId)
substFun f@FNative {} = return f
substFun f@FDefun {..} = do
  -- make fake App for top-level fun
  -- app <- App <$> freshId Nothing "_top_" <*> pure f <*>
  b' <- mapM (walkAST processNatives) =<< mapM (walkAST $ substAppDefun Nothing) _fBody
  pivot
  --use tcPivot >>= liftIO . putDoc . prettyPivot
  eliminate
  buildSolverGraph
  return $ set fBody b' f

_loadFun :: FilePath -> ModuleName -> String -> IO (Term Ref)
_loadFun fp mn fn = do
  (r,s) <- execScript' (Script fp) fp
  either (die def) (const (return ())) r
  let (Just (Just (Ref d))) = firstOf (rEnv . eeRefStore . rsModules . at mn . _Just . at fn) s
  return d

_infer :: FilePath -> ModuleName -> String -> IO (Fun TcId, TcState)
_infer fp mn fn = _loadFun fp mn fn >>= \d -> runTC (infer d >>= substFun)

_inferIssue :: IO (Fun TcId, TcState)
_inferIssue = _infer "examples/cp/cp-notest.repl" "cp" "issue"
