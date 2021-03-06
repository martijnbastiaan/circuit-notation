{-
 ██████╗██╗██████╗  ██████╗██╗   ██╗██╗████████╗███████╗
██╔════╝██║██╔══██╗██╔════╝██║   ██║██║╚══██╔══╝██╔════╝
██║     ██║██████╔╝██║     ██║   ██║██║   ██║   ███████╗
██║     ██║██╔══██╗██║     ██║   ██║██║   ██║   ╚════██║
╚██████╗██║██║  ██║╚██████╗╚██████╔╝██║   ██║   ███████║
 ╚═════╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝
  (C) 2020, Christopher Chalmers

Notation for describing the 'Circuit' type.
-}

{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module CircuitNotation (plugin) where

-- base
import           Control.Exception
import           Control.Monad.IO.Class (MonadIO (..))
import qualified Data.Data              as Data
import           Data.Default
import           Data.Maybe             (fromMaybe)
import           SrcLoc
import           System.IO.Unsafe

-- ghc
import           Bag
import qualified Convert
import qualified ErrUtils               as Err
import           FastString             (mkFastString, unpackFS)
import qualified GhcPlugins             as GHC
import           HscTypes               (throwOneError)
import           HsExtension            (GhcPs, NoExt (..))
import           HsSyn
import qualified HsTypes
import qualified Language.Haskell.TH    as TH
import qualified OccName
import qualified Outputable
import           PrelNames              (eqTyCon_RDR)

-- containers
import Data.Map (Map)
import qualified Data.Map as Map

-- lens
import qualified Control.Lens           as L
import           Control.Lens.Operators

-- mtl
import           Control.Monad.State

-- pretty-show
-- import qualified Text.Show.Pretty       as SP

-- syb
import qualified Data.Generics          as SYB

-- The stages of this plugin
--
-- 1. Go through the parsed module source and find usages of the circuit keyword (`transform`).
-- 2. Parse the circuit, either do notation or a one liner, go through each statement and convert it
--    to a CircuitQQ.
-- 3. Go through the CircuitQQ and check that everything is consistent (every master has a matching
--    slave).
-- 4. Convert the Bindings to let statements, at the same time build up a description of the types
--    to make the type descriptor helper.

-- Names ---------------------------------------------------------------

constructorName, typeConstructorName, circuitTypeName, runCircuitName :: String
constructorName = "Circuit"
typeConstructorName = "Circuit"
circuitTypeName = "CircuitT"
runCircuitName = "runCircuit"

-- Utils ---------------------------------------------------------------

isCircuitVar :: p ~ GhcPs => HsExpr p -> Bool
isCircuitVar = \case
  HsVar _ (L _ v) -> v == GHC.mkVarUnqual "circuit"
  _               -> False

isDollar :: p ~ GhcPs => HsExpr p -> Bool
isDollar = \case
  HsVar _ (L _ v) -> v == GHC.mkVarUnqual "$"
  _               -> False

imap :: (Int -> a -> b) -> [a] -> [b]
imap f = zipWith f [0 ..]

-- Types ---------------------------------------------------------------

-- | The name given to a 'port', i.e. the name of a variable either to the left of a '<-' or to the
--   right of a '-<'.
data PortName = PortName SrcSpan GHC.FastString
  deriving (Eq, Ord)

instance Show PortName where
  show (PortName _ fs) = GHC.unpackFS fs

data PortDescription a
    = Tuple [PortDescription a]
    | Vec SrcSpan [PortDescription a]
    | Ref a
    | Lazy SrcSpan (PortDescription a)
    | SignalExpr (LHsExpr GhcPs)
    | SignalPat (LPat GhcPs)
    | PortType (LHsSigWcType GhcPs) (PortDescription a)
    | PortErr SrcSpan Err.MsgDoc
    deriving (Foldable, Functor, Traversable)

_Ref :: L.Prism' (PortDescription a) a
_Ref = L.prism' Ref (\case Ref a -> Just a; _ -> Nothing)

instance L.Plated (PortDescription a) where
  plate f = \case
    Tuple ps -> Tuple <$> traverse f ps
    Vec s ps -> Vec s <$> traverse f ps
    Lazy s p -> Lazy s <$> f p
    PortType t p -> PortType t <$> f p
    p -> pure p

-- | A single circuit binding. These are generated from parsing statements.
-- @
-- bOut <- bCircuit -< bIn
-- @
data Binding exp l = Binding
    { bCircuit :: exp
    , bOut     :: PortDescription l
    , bIn      :: PortDescription l
    }
    deriving (Functor)

data CircuitState dec exp nm = CircuitState
    { _cErrors        :: Bag Err.ErrMsg
    , _counter        :: Int
    -- ^ unique counter for generated variables
    , _circuitSlaves  :: PortDescription nm
    -- ^ the final statement in a circuit
    , _circuitTypes   :: [LSig GhcPs]
    -- ^ type signatures in let bindings
    , _circuitLets    :: [dec]
    -- ^ user defined let expression inside the circuit
    , _circuitBinds   :: [Binding exp nm]
    -- ^ @out <- circuit <- in@ statements
    , _circuitMasters :: PortDescription nm
    -- ^ ports bound at the first lambda of a circuit
    , _portVarTypes :: Map GHC.FastString (SrcSpan, LHsType GhcPs)
    -- ^ types of single variable ports
    , _portTypes :: [(LHsSigWcType GhcPs, PortDescription nm)]
    -- ^ type of more 'complicated' things (very far from vigorous)
    , _uniqueCounter :: Int
    -- ^ counter to keep internal variables "unique"
    }

L.makeLenses 'CircuitState

-- | The monad used when running a single circuit.
newtype CircuitM a = CircuitM (StateT (CircuitState (LHsBind GhcPs) (LHsExpr GhcPs) PortName) GHC.Hsc a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadState (CircuitState (LHsBind GhcPs) (LHsExpr GhcPs) PortName))

instance GHC.HasDynFlags CircuitM where
  getDynFlags = (CircuitM . lift) GHC.getDynFlags

runCircuitM :: CircuitM a -> GHC.Hsc a
runCircuitM (CircuitM m) = do
  let emptyCircuitState = CircuitState
        { _cErrors = emptyBag
        , _counter = 0
        , _circuitSlaves = Tuple []
        , _circuitTypes = []
        , _circuitLets = []
        , _circuitBinds = []
        , _circuitMasters = Tuple []
        , _portVarTypes = Map.empty
        , _portTypes = []
        , _uniqueCounter = 1
        }
  (a, s) <- runStateT m emptyCircuitState
  let errs = _cErrors s
  unless (isEmptyBag errs) $ liftIO . throwIO $ GHC.mkSrcErr errs
  pure a

errM :: SrcSpan -> String -> CircuitM ()
errM loc msg = do
  dflags <- GHC.getDynFlags
  let errMsg = Err.mkLocMessageAnn Nothing Err.SevFatal loc (Outputable.text msg)
  cErrors %= consBag (Err.mkErrMsg dflags loc Outputable.alwaysQualify errMsg)

-- ghc helpers ---------------------------------------------------------

-- It's very possible that most of these are already in the ghc library in some form. It's not the
-- easiest library to descover these kind of functions.

tupP :: p ~ GhcPs => [LPat p] -> LPat p
tupP [pat] = pat
tupP pats = noLoc $ TuplePat NoExt pats GHC.Boxed

vecP :: p ~ GhcPs => SrcSpan -> [LPat p] -> LPat p
vecP loc (p@(L l _):pats) = L loc $ ConPatIn (L l (con "Cons")) (PrefixCon [p, vecP loc pats])
vecP loc [] = L loc $ ConPatIn (L loc (con "Nil")) (PrefixCon [])

varP :: p ~ GhcPs => SrcSpan -> String -> LPat p
varP loc nm = L loc $ VarPat NoExt (L loc $ var nm)

tildeP :: p ~ GhcPs => SrcSpan -> LPat p -> LPat p
tildeP loc lpat = L loc (LazyPat NoExt lpat)

tupT :: p ~ GhcPs => [LHsType p] -> LHsType p
tupT [ty] = ty
tupT tys = noLoc $ HsTupleTy NoExt HsBoxedTuple tys

vecT :: p ~ GhcPs => SrcSpan -> [LHsType p] -> LHsType p
vecT s [] = L s $ HsParTy NoExt (conT s "Vec" `appTy` tyNum s 0 `appTy` (varT s (genLocName s "vec")))
vecT s tys = L s $ HsParTy NoExt (conT s "Vec" `appTy` tyNum s (length tys) `appTy` head tys)

tyNum :: p ~ GhcPs => SrcSpan -> Int -> LHsType p
tyNum s i = L s (HsTyLit NoExt (HsNumTy GHC.NoSourceText (fromIntegral i)))

appTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
appTy a b = L noSrcSpan (HsAppTy NoExt a (parenthesizeHsType GHC.appPrec b))

appE :: p ~ GhcPs => LHsExpr p -> LHsExpr p -> LHsExpr p
appE fun arg = L noSrcSpan $ HsApp NoExt fun (parenthesizeHsExpr GHC.appPrec arg)

varE :: p ~ GhcPs => SrcSpan -> GHC.RdrName -> LHsExpr p
varE loc rdr = L loc (HsVar NoExt (L loc rdr))

parenE :: p ~ GhcPs => LHsExpr p -> LHsExpr p
parenE e@(L l _) = L l (HsPar NoExt e)

var :: String -> GHC.RdrName
var = GHC.Unqual . OccName.mkVarOcc

tyVar :: String -> GHC.RdrName
tyVar = GHC.Unqual . OccName.mkTyVarOcc

tyCon :: String -> GHC.RdrName
tyCon = GHC.Unqual . OccName.mkTcOcc

con :: String -> GHC.RdrName
con = GHC.Unqual . OccName.mkDataOcc

vecE :: p ~ GhcPs => SrcSpan -> [LHsExpr p] -> LHsExpr p
vecE loc (e@(L l _):es) = varE l (con "Cons") `appE` e `appE` parenE (vecE loc es)
vecE loc [] = varE loc (con "Nil")

tupE :: p ~ GhcPs => SrcSpan -> [LHsExpr p] -> LHsExpr p
tupE _ [ele] = ele
tupE loc elems = L loc $ ExplicitTuple NoExt tupArgs GHC.Boxed
  where
    tupArgs = map (\arg@(L l _) -> L l (Present NoExt arg)) elems

unL :: Located a -> a
unL (L _ a) = a

-- | Get a ghc name from a TH name that's known to be unique.
thName :: TH.Name -> GHC.RdrName
thName nm =
  case Convert.thRdrNameGuesses nm of
    [name] -> name
    _      -> error "thName called on a non NameG Name"

-- | Make a type signature from a port description. Things without a concrete type (e.g. Signal a),
--   are given a type name based on the location of the port.
portTypeSigM :: p ~ GhcPs => PortDescription PortName -> CircuitM (LHsType p)
portTypeSigM = \case
  Tuple ps -> tupT <$> mapM portTypeSigM ps
  Vec s ps -> vecT s <$> mapM portTypeSigM ps
  Ref (PortName loc fs) -> do
    L.use (portVarTypes . L.at fs) <&> \case
      Nothing -> varT loc (GHC.unpackFS fs <> "Ty")
      Just (_sigLoc, sig) -> sig
  PortErr loc msgdoc -> do
    dflags <- GHC.getDynFlags
    unsafePerformIO . throwOneError $
      Err.mkLongErrMsg dflags loc Outputable.alwaysQualify (Outputable.text "portTypeSig") msgdoc
  Lazy _ p -> portTypeSigM p
  SignalExpr (L l _) -> do
    n <- uniqueCounter <<+= 1
    pure $ (conT l "Signal") `appTy` (varT l (genLocName l "dom")) `appTy` (varT l (genLocName l ("sig_" <> show n)))
  SignalPat (L l _) -> do
    n <- uniqueCounter <<+= 1
    pure $ (conT l "Signal") `appTy` (varT l (genLocName l "dom")) `appTy` (varT l (genLocName l ("sig_" <> show n)))
  PortType _ p -> portTypeSigM p

-- | Generate a "unique" name by appending the location as a string.
genLocName :: SrcSpan -> String -> String
genLocName (GHC.RealSrcSpan rss) prefix = prefix <> "_" <>
  foldMap (\f -> show (f rss)) [srcSpanStartLine, srcSpanEndLine, srcSpanStartCol, srcSpanEndCol]
genLocName _ prefix = prefix

-- | Extract a simple lambda into inputs and body.
simpleLambda :: HsExpr p -> Maybe ([LPat p], LHsExpr p)
simpleLambda expr = do
  HsLam _ (MG _x alts _origin) <- Just expr
  L _ [L _ (Match _matchX _matchContext matchPats matchGr)] <- Just alts
  GRHSs _grX grHss _grLocalBinds <- Just matchGr
  [L _ (GRHS _ _ body)] <- Just grHss
  Just (matchPats, body)

-- | Create a simple let binding.
letE
  :: p ~ GhcPs
  => SrcSpan
  -- ^ location for top level let bindings
  -> [LSig GhcPs]
  -- ^ type signatures
  -> [LHsBind p]
  -- ^ let bindings
  -> LHsExpr p
  -- ^ final `in` expressions
  -> LHsExpr p
letE loc sigs binds expr = L loc (HsLet NoExt localBinds expr)
  where
    localBinds :: LHsLocalBindsLR GhcPs GhcPs
    localBinds = L loc $ HsValBinds NoExt valBinds

    valBinds :: HsValBindsLR GhcPs GhcPs
    valBinds = ValBinds NoExt hsBinds sigs

    hsBinds :: LHsBindsLR GhcPs GhcPs
    hsBinds = listToBag binds

-- | Simple construction of a lamda expression
lamE :: p ~ GhcPs => [LPat p] -> LHsExpr p -> LHsExpr p
lamE pats expr = noLoc $ HsLam NoExt mg
  where
    mg = MG NoExt matches GHC.Generated

    matches :: Located [LMatch GhcPs (LHsExpr GhcPs)]
    matches = noLoc $ [singleMatch]

    singleMatch :: LMatch GhcPs (LHsExpr GhcPs)
    singleMatch = noLoc $ Match NoExt LambdaExpr pats grHss

    grHss :: GRHSs GhcPs (LHsExpr GhcPs)
    grHss = GRHSs NoExt [grHs] (noLoc $ EmptyLocalBinds NoExt)

    grHs :: LGRHS GhcPs (LHsExpr GhcPs)
    grHs = noLoc $ GRHS NoExt [] expr

-- | Kinda hacky function to get a string name for named ports.
fromRdrName :: GHC.RdrName -> GHC.FastString
fromRdrName = \case
  GHC.Unqual occName -> mkFastString (OccName.occNameString occName)
  GHC.Orig _ occName -> mkFastString (OccName.occNameString occName)
  nm -> mkFastString (deepShowD nm)

-- Parsing -------------------------------------------------------------

-- | "parse" a circuit, i.e. convert it from ghc's ast to our representation of a circuit. This is
-- the expression following the 'circuit' keyword.
parseCircuit
  :: p ~ GhcPs
  => LHsExpr p
  -> CircuitM ()
parseCircuit = \case
  -- strip out parenthesis
  L _ (HsPar _ lexp) -> parseCircuit lexp

  -- a lambda to match the slave ports
  L _ (simpleLambda -> Just ([matchPats], body)) -> do
    circuitSlaves .= bindSlave matchPats
    circuitBody body

  -- a version without a lamda (i.e. no slaves)
  e -> circuitBody e

-- | The main part of a circuit expression. Either a do block or simple rearranging case.
circuitBody
  :: p ~ GhcPs
  => LHsExpr p
  -> CircuitM ()
circuitBody = \case
  -- strip out parenthesis
  L _ (HsPar _ lexp) -> circuitBody lexp

  L _ (HsDo _x _stmtContext (L _ (unsnoc -> Just (stmts, L finLoc finStmt)))) -> do
    mapM_ handleStmtM stmts

    case finStmt of
      BodyStmt _bodyX bod _idr _idr' ->
        case bod of
          -- special case for idC as the final statement, gives better type inferences and generates nicer
          -- code
          L _ (HsArrApp _xapp (L _ (HsVar _ (L _ (GHC.Unqual occ)))) arg _ _)
            | OccName.occNameString occ == "idC" -> circuitMasters .= bindMaster arg

          -- Otherwise create a binding and use that as the master. This is equivalent to changing
          --   c -< x
          -- into
          --   finalStmt <- c -< x
          --   idC -< finalStmt
          _ -> do
            let ref = Ref (PortName finLoc "final:stmt")
            bodyBinding (Just ref) (bod)
            circuitMasters .= ref

      stmt -> errM finLoc ("Unhandled final stmt " <> show (Data.toConstr stmt))

  -- the simple case without do notation
  L loc master -> circuitMasters .= bindMaster (L loc master)

-- | Handle a single statement.
handleStmtM
  :: (p ~ GhcPs, loc ~ SrcSpan, idL ~ GhcPs, idR ~ GhcPs)
  => Located (StmtLR idL idR (LHsExpr p))
  -> CircuitM ()
handleStmtM (L loc stmt) = case stmt of
  LetStmt _xlet (L _ letBind) ->
    -- a regular let bindings
    case letBind of
      HsValBinds _ (ValBinds _ valBinds sigs) -> do
        circuitLets <>= bagToList valBinds
        circuitTypes <>= sigs
      _ -> errM loc ("Unhandled let statement" <> show (Data.toConstr letBind))
  BodyStmt _xbody body _idr _idr' ->
    bodyBinding Nothing body
  BindStmt _xbody bind body _idr _idr' ->
    bodyBinding (Just $ bindSlave bind) body
  _ -> errM loc "Unhandled stmt"

-- | Turn patterns to the left of a @<-@ into a PortDescription.
bindSlave :: p ~ GhcPs => LPat p -> PortDescription PortName
bindSlave (L loc expr) = case expr of
  VarPat _ (L _ rdrName) -> Ref (PortName loc (fromRdrName rdrName))
  TuplePat _ lpat _ -> Tuple $ fmap bindSlave lpat
  ParPat _ lpat -> bindSlave lpat
  ConPatIn (L _ (GHC.Unqual occ)) (PrefixCon [lpat])
    | OccName.occNameString occ == "Signal" -> SignalPat lpat
  -- empty list is done as the constructor
  ConPatIn (L _ rdr) _
    | rdr == thName '[] -> Vec loc []
    | rdr == thName '() -> Tuple []
  SigPat ty port -> PortType ty (bindSlave port)
  LazyPat _ lpat -> Lazy loc (bindSlave lpat)
  ListPat _ pats -> Vec loc (map bindSlave pats)
  pat ->
    PortErr loc
            (Err.mkLocMessageAnn
              Nothing
              Err.SevFatal
              loc
              (Outputable.text $ "Unhandled pattern " <> show (Data.toConstr pat))
              )

-- | Turn expressions to the right of a @-<@ into a PortDescription.
bindMaster :: p ~ GhcPs => LHsExpr p -> PortDescription PortName
bindMaster (L loc expr) = case expr of
  HsVar _xvar (L vloc rdrName)
    | rdrName == thName '() -> Tuple []
    | rdrName == thName '[] -> Vec vloc []
    | otherwise -> Ref (PortName vloc (fromRdrName rdrName))
  ExplicitTuple _ tups _ -> let
    vals = fmap (\(L _ (Present _ e)) -> e) tups
    in Tuple $ fmap bindMaster vals
  ExplicitList _ _syntaxExpr exprs -> Vec loc $ fmap bindMaster exprs
  HsApp _xapp (L _ (HsVar _ (L _ (GHC.Unqual occ)))) sig
    | OccName.occNameString occ == "Signal" -> SignalExpr sig
  ExprWithTySig ty expr' -> PortType ty (bindMaster expr')
  ELazyPat _ expr' -> Lazy loc (bindMaster expr')

  -- OpApp _xapp (L _ circuitVar) (L _ infixVar) appR -> k

  _ -> PortErr loc
    (Err.mkLocMessageAnn
      Nothing
      Err.SevFatal
      loc
      (Outputable.text $ "Unhandled expression " <> show (Data.toConstr expr))
      )

-- | Create a binding expression
bodyBinding
  :: (p ~ GhcPs, loc ~ SrcSpan)
  => Maybe (PortDescription PortName)
  -- ^ the bound variable, this can be Nothing if there is no @<-@ (a circuit with no slaves)
  -> GenLocated loc (HsExpr p)
  -- ^ the statement with an optional @-<@
  -> CircuitM ()
bodyBinding mInput lexpr@(L loc expr) =
  case expr of
    HsArrApp _xhsArrApp circuit port HsFirstOrderApp True ->
      circuitBinds <>= [Binding
        { bCircuit = circuit
        , bOut     = bindMaster port
        , bIn      = fromMaybe (Tuple []) mInput
        }]

    _ -> case mInput of
      Nothing -> errM loc "standalone expressions are not allowed (are Arrows enabled?)"
      Just input -> circuitBinds <>= [Binding
        { bCircuit = lexpr
        , bOut     = Tuple []
        , bIn      = input
        }]

-- Checking ------------------------------------------------------------

data Dir = Slave | Master

checkCircuit :: p ~ GhcPs => CircuitM ()
checkCircuit = do
  slaves <- L.use circuitSlaves
  masters <- L.use circuitMasters
  binds <- L.use circuitBinds

  let portNames d = L.toListOf (L.cosmos . _Ref . L.to (f d))
      f :: Dir -> PortName -> (GHC.FastString, ([SrcSpan], [SrcSpan]))
      f Slave (PortName srcLoc portName) = (portName, ([srcLoc], []))
      f Master (PortName srcLoc portName) = (portName, ([], [srcLoc]))
      bindingNames = \b -> portNames Master (bOut b) <> portNames Slave (bIn b)
      topNames = portNames Slave slaves <> portNames Master masters
      nameMap = Map.fromListWith mappend $ topNames <> concatMap bindingNames binds

  L.iforM_ nameMap \name occ ->
    case occ of
      ([_], [_]) -> pure ()
      (ss, ms) -> do
        unless (head (unpackFS name) == '_') $ do
          when (null ms) $ errM (head ss) $ "Slave port " <> show name <> " has no assosiated master"
          when (null ss) $ errM (head ms) $ "Master port " <> show name <> " has no assosiated slave"
        -- would be nice to show locations of all occurances here, not sure how to do that while
        -- keeping ghc api
        when (length ms > 1) $
          errM (head ms) $ "Master port " <> show name <> " defined " <> show (length ms) <> " times"
        when (length ss > 1) $
          errM (head ss) $ "Slave port " <> show name <> " defined " <> show (length ss) <> " times"

-- Creating ------------------------------------------------------------

bindWithSuffix :: p ~ GhcPs => GHC.DynFlags -> String -> PortDescription PortName -> LPat p
bindWithSuffix dflags suffix = \case
  Tuple ps -> tildeP noSrcSpan $ tupP $ fmap (bindWithSuffix dflags suffix) ps
  Vec s ps -> vecP s $ fmap (bindWithSuffix dflags suffix) ps
  Ref (PortName loc fs) -> varP loc (GHC.unpackFS fs <> suffix)
  PortErr loc msgdoc -> unsafePerformIO . throwOneError $
    Err.mkLongErrMsg dflags loc Outputable.alwaysQualify (Outputable.text "Unhandled bind") msgdoc
  Lazy loc p -> tildeP loc $ bindWithSuffix dflags suffix p
  SignalExpr (L l _) -> L l (WildPat NoExt)
  SignalPat lpat -> lpat
  PortType _ p -> bindWithSuffix dflags suffix p

data Direc = Fwd | Bwd

bindOutputs
  :: p ~ GhcPs
  => GHC.DynFlags
  -> Direc
  -> PortDescription PortName
  -- ^ slave ports
  -> PortDescription PortName
  -- ^ master ports
  -> LPat p
bindOutputs dflags Fwd slaves masters = noLoc $ ConPatIn (noLoc $ con ":->") (InfixCon m2s s2m)
  where
  m2s = bindWithSuffix dflags "_Fwd" masters
  s2m = bindWithSuffix dflags "_Bwd" slaves
bindOutputs dflags Bwd slaves masters = noLoc $ ConPatIn (noLoc $ con ":->") (InfixCon m2s s2m)
  where
  m2s = bindWithSuffix dflags "_Bwd" masters
  s2m = bindWithSuffix dflags "_Fwd" slaves

expWithSuffix :: p ~ GhcPs => String -> PortDescription PortName -> LHsExpr p
expWithSuffix suffix = \case
  Tuple ps -> tupE noSrcSpan $ fmap (expWithSuffix suffix) ps
  Vec s ps -> vecE s $ fmap (expWithSuffix suffix) ps
  Ref (PortName loc fs)   -> varE loc (var $ GHC.unpackFS fs <> suffix)
  -- lazyness only affects the pattern side
  Lazy _ p   -> expWithSuffix suffix p
  PortErr _ _ -> error "expWithSuffix PortErr!"
  SignalExpr lexpr -> lexpr
  SignalPat (L l _) -> tupE l []
  PortType _ p -> expWithSuffix suffix p

createInputs
  :: p ~ GhcPs
  => Direc
  -> PortDescription PortName
  -- ^ slave ports
  -> PortDescription PortName
  -- ^ master ports
  -> LHsExpr p
createInputs Fwd slaves masters = noLoc $ OpApp NoExt s2m (varE noSrcSpan (con ":->")) m2s
  where
  m2s = expWithSuffix "_Bwd" masters
  s2m = expWithSuffix "_Fwd" slaves
createInputs Bwd slaves masters = noLoc $ OpApp NoExt s2m (varE noSrcSpan (con ":->")) m2s
  where
  m2s = expWithSuffix "_Fwd" masters
  s2m = expWithSuffix "_Bwd" slaves

decFromBinding :: p ~ GhcPs => GHC.DynFlags -> Int -> Binding (LHsExpr p) PortName -> HsBind p
decFromBinding dflags i Binding {..} = do
  let bindPat  = bindOutputs dflags Bwd bIn bOut
      inputExp = createInputs Fwd bOut bIn
      bod = varE noSrcSpan (var $ "run" <> show i) `appE` bCircuit `appE` inputExp
   in patBind bindPat bod

patBind :: p ~ GhcPs => LPat p -> LHsExpr p -> HsBind p
patBind lhs expr = PatBind NoExt lhs rhs ([], [])
  where
    rhs = GRHSs NoExt [gr] (noLoc $ EmptyLocalBinds NoExt)
    gr  = L (getLoc expr) (GRHS NoExt [] expr)

circuitConstructor :: p ~ GhcPs => SrcSpan -> LHsExpr p
circuitConstructor loc = varE loc (con constructorName)

runCircuitFun :: p ~ GhcPs => SrcSpan -> LHsExpr p
runCircuitFun loc = varE loc (var runCircuitName)

constVar :: p ~ GhcPs => SrcSpan -> LHsExpr p
constVar loc = varE loc (thName 'const)

deepShowD :: Data.Data a => a -> String
deepShowD a = show (Data.toConstr a) <>
  -- " (" <> (unwords . fst) (SYB.gmapM (\x -> ([show $ Data.toConstr x], x)) a) <> ")"
  " (" <> (unwords . fst) (SYB.gmapM (\x -> ([deepShowD x], x)) a) <> ")"

unsnoc :: [a] -> Maybe ([a], a)
unsnoc [] = Nothing
unsnoc [x] = Just ([], x)
unsnoc (x:xs) = Just (x:a, b)
    where Just (a,b) = unsnoc xs

arrTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
arrTy a b = noLoc $ HsFunTy NoExt (parenthesizeHsType GHC.funPrec a) (parenthesizeHsType GHC.funPrec b)

varT :: SrcSpan -> String -> LHsType GhcPs
varT loc nm = L loc (HsTyVar NoExt NotPromoted (L loc (tyVar nm)))

conT :: SrcSpan -> String -> LHsType GhcPs
conT loc nm = L loc (HsTyVar NoExt NotPromoted (L loc (tyCon nm)))

circuitTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
circuitTy a b = (conT noSrcSpan typeConstructorName) `appTy` a `appTy` b

circuitTTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
circuitTTy a b = (conT noSrcSpan circuitTypeName) `appTy` a `appTy` b

-- a b -> (Circuit a b -> CircuitT a b)
mkRunCircuitTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
mkRunCircuitTy a b = noLoc $ HsFunTy noExt (circuitTy a b) (circuitTTy a b)

-- a b -> (CircuitT a b -> Circuit a b)
mkCircuitTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
mkCircuitTy a b = noLoc $ HsFunTy noExt (circuitTTy a b) (circuitTy a b)

-- perhaps this should happen on construction
gatherTypes
  :: p ~ GhcPs
  => PortDescription PortName
  -> CircuitM ()
gatherTypes = L.traverseOf_ L.cosmos addTypes
  where
    addTypes = \case
      PortType ty (Ref (PortName loc fs)) -> portVarTypes . L.at fs ?= (loc, hsSigWcType ty)
      PortType ty p -> portTypes <>= [(ty, p)]
      _             -> pure ()

tyEq :: p ~ GhcPs => SrcSpan -> LHsType p -> LHsType p -> LHsType p
tyEq l a b = L l $ HsOpTy NoExt a (noLoc eqTyCon_RDR) b
-- eqTyCon is a special name that has to be exactly correct for ghc to recognise it. In 8.6 this
-- lives in PrelNames and is called eqTyCon_RDR, in later ghcs it's from TysWiredIn.

-- Final construction --------------------------------------------------

circuitQQExpM
  :: p ~ GhcPs
  => CircuitM (LHsExpr p)
circuitQQExpM = do
  checkCircuit

  dflags <- GHC.getDynFlags
  binds <- L.use circuitBinds
  lets <- L.use circuitLets
  slaves <- L.use circuitSlaves
  masters <- L.use circuitMasters

  -- Construction of the circuit expression
  let decs = concat
        [ lets
        , imap (\i -> noLoc . decFromBinding dflags i) binds
        ]
  let pats = bindOutputs dflags Fwd masters slaves
      res  = createInputs Bwd slaves masters

      body :: LHsExpr GhcPs
      body = letE noSrcSpan [] decs res

  -- see [inference-helper]
  mapM_
    (\(Binding _ outs ins) -> gatherTypes outs >> gatherTypes ins)
    binds
  mapM_ gatherTypes [masters, slaves]

  slavesTy <- portTypeSigM slaves
  mastersTy <- portTypeSigM masters
  let mkRunTy bind =
        mkRunCircuitTy <$>
          (portTypeSigM (bOut bind)) <*>
          (portTypeSigM (bIn bind))
  bindTypes <- mapM mkRunTy binds
  let runCircuitsType =
        noLoc (HsParTy NoExt (tupT bindTypes `arrTy` circuitTTy slavesTy mastersTy))
          `arrTy` circuitTy slavesTy mastersTy

  allTypes <- L.use portTypes

  context <- mapM (\(ty, p) -> tyEq noSrcSpan <$> (portTypeSigM p) <*> pure (HsTypes.hsSigWcType ty)) allTypes

  -- the full signature
  let inferenceSig :: LHsSigType GhcPs
      inferenceSig = HsIB NoExt (noLoc $ HsQualTy NoExt (noLoc context) runCircuitsType)
      inferenceHelperTy =
        TypeSig NoExt
          [noLoc (var "inferenceHelper")]
          (HsWC NoExt inferenceSig)

  let numBinds = length binds
      runCircuitExprs = lamE [varP noSrcSpan "f"] $
        circuitConstructor noSrcSpan `appE`
          noLoc (HsPar NoExt
          (varE noSrcSpan (var "f") `appE` tupE noSrcSpan (replicate numBinds (runCircuitFun noSrcSpan))))
      runCircuitBinds = tupP $ map (\i -> varP noSrcSpan ("run" <> show i)) [0 .. numBinds-1]

  let c = letE noSrcSpan
            [noLoc inferenceHelperTy]
            [noLoc $ patBind (varP noSrcSpan "inferenceHelper") (runCircuitExprs)]
            (varE noSrcSpan (var "inferenceHelper") `appE` lamE [runCircuitBinds, pats] body)
  -- ppr c
  pure c

  -- pure $ varE noSrcSpan (var "undefined")

-- [inference-helper]
-- The inference helper constructs the circuit and provides all the `runCircuit`s with the types
-- matching the structure of the port expressions. This way we can enforce that ports 'keep the
-- same type' which normally gets lost when deconstructing and reconstructing types. It also means
-- that we can add type annotations of the ports as a context to this helper function. For example
--
-- swapIC c = circuit $ \(a :: Int, b) -> do
--   a' <- c -< a
--   b' <- c -< b
--   idC -< (b',a')
--
-- will produce the helper
--
-- inferenceHelper ::
--   aTy ~ Int =>
--   -> (   (Circuit aTy a'Ty -> CircuitT aTy a'Ty)
--       -> (Circuit bTy b'Ty -> CircuitT bTy b'Ty)
--       -> CircuitT (aTy, bTy) (b'Ty, a'Ty)
--      ) -> CircuitT (aTy, bTy) (b'Ty, a'Ty)
-- inferenceHelper = \f -> Circuit (f runCircuit runCircuit)


grr :: MonadIO m => OccName.NameSpace -> m ()
grr nm
  | nm == OccName.tcName = liftIO $ putStrLn "tcName"
  | nm == OccName.clsName = liftIO $ putStrLn "clsName"
  | nm == OccName.tcClsName = liftIO $ putStrLn "tcClsName"
  | nm == OccName.dataName = liftIO $ putStrLn "dataName"
  | nm == OccName.varName = liftIO $ putStrLn "varName"
  | nm == OccName.tvName = liftIO $ putStrLn "tvName"
  | otherwise = liftIO $ putStrLn "I dunno"

completeUnderscores :: CircuitM ()
completeUnderscores = do
  binds <- L.use circuitBinds
  masters <- L.use circuitMasters
  slaves <- L.use circuitSlaves
  let addDef :: String -> PortDescription PortName -> CircuitM ()
      addDef suffix = \case
        Ref (PortName loc (unpackFS -> name@('_':_))) -> do
          let bind = patBind (varP loc (name <> suffix)) (varE loc (thName 'def))
          circuitLets <>= [L loc bind]

        _ -> pure ()
      addBind :: Binding exp PortName -> CircuitM ()
      addBind (Binding _ bOut bIn) = do
        L.traverseOf_ L.cosmos (addDef "_Fwd") bOut
        L.traverseOf_ L.cosmos (addDef "_Bwd") bIn
  mapM_ addBind binds
  addBind (Binding undefined masters slaves)


-- | Transform declations in the module by converting circuit blocks.
transform
    :: GHC.Located (HsModule GhcPs)
    -> GHC.Hsc (GHC.Located (HsModule GhcPs))
transform = SYB.everywhereM (SYB.mkM transform') where
  transform' :: LHsExpr GhcPs -> GHC.Hsc (LHsExpr GhcPs)
  -- transform' e@(L _ (HsLet _xlet (L _ (HsValBinds _ (ValBinds _ _ sigs))) _lappB)) =
-- --  -- --                debug $ show i ++ " ==> " ++ SYB.gshow stmt
  --   -- trace (show (SYB.gshow <$> sigs)) pure e
  --   -- trace (show (( \ (TypeSig _ ids ty) -> show (deepShowD <$> ids) <> " " <> deepShowD ty) . unL <$> sigs)) pure e
  --   case sigs of
  --     [L _ (TypeSig _ [L _ x] y)] -> do
  --       -- dflags <- GHC.getDynFlags
  --       let pp :: GHC.Outputable a => a -> String
  --           pp = const "" -- GHC.showPpr dflags
  --       case y of
  --         HsWC _ (HsIB _ (L _ (HsTyVar _ _ (L _ (GHC.Unqual occ))))) -> do
  --           grr (OccName.occNameSpace occ)
  --         HsWC _ (HsIB _ (L _ (HsQualTy _ (L _ [L _ (HsOpTy NoExt _ (L _ (GHC.Orig m nm)) _)]) _))) -> do
  --           grr $ OccName.occNameSpace nm
  --           traceM (pp m)
  --         _ -> pure () -- error "nope"
  --       trace (pp x) trace (SYB.gshow y) pure e
  --       -- error "fin"
  --     _ -> pure e

  -- the circuit keyword directly applied (either with parenthesis or with BlockArguments)
  transform' (L _ (HsApp _xapp (L _ circuitVar) lappB))
    | isCircuitVar circuitVar = runCircuitM $ do
        parseCircuit lappB >> completeUnderscores >> circuitQQExpM

  -- `circuit $` application
  transform' (L _ (OpApp _xapp (L _ circuitVar) (L _ infixVar) appR))
    | isCircuitVar circuitVar && isDollar infixVar = do
        runCircuitM $ do
          parseCircuit appR >> completeUnderscores >> circuitQQExpM

  transform' e = pure e

-- | The plugin for circuit notation.
plugin :: GHC.Plugin
plugin = GHC.defaultPlugin
  { GHC.parsedResultAction = \_cliOptions -> pluginImpl
  }

-- | The actual implementation.
pluginImpl :: GHC.ModSummary -> GHC.HsParsedModule -> GHC.Hsc GHC.HsParsedModule
pluginImpl _modSummary m = do
    -- dflags <- GHC.getDynFlags
    -- debug $ GHC.showPpr dflags (GHC.hpm_module m)
    hpm_module' <- transform (GHC.hpm_module m)
    let module' = m { GHC.hpm_module = hpm_module' }
    return module'


-- Debugging functions -------------------------------------------------

ppr :: GHC.Outputable a => a -> CircuitM ()
ppr a = do
  dflags <- GHC.getDynFlags
  liftIO $ putStrLn (GHC.showPpr dflags a)

-- showC :: Data.Data a => a -> String
-- showC a = show (typeOf a) <> " " <> show (Data.toConstr a)

-- ppp :: MonadIO m => String -> m ()
-- ppp s = case SP.parseValue s of
--   Just a -> valToStr a
