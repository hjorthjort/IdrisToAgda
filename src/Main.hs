module Main where

import Agda.Syntax.Concrete
import Agda.Syntax.Concrete.Pretty
import qualified Agda.Syntax.Abstract.Name as AAbstract
import Agda.Utils.Pretty
import Agda.Syntax.Position
import Agda.Syntax.Literal
import Agda.Syntax.Common
import Agda.Syntax.Fixity
import Agda.Syntax.Notation
import Idris.Parser (loadModule, prog)
import Idris.Parser.Stack
import Idris.AbsSyntax
import Idris.Docstrings
import Idris.IBC
import Idris.Info (getIdrisLibDir)
import Idris.ElabDecls (elabPrims, elabDecls)
import Idris.Core.Evaluate (definitions, TTDecl, Def, Def(..))
import qualified Idris.Core.TT as TT

import Util.System (readSource)

import Data.List (intersperse)
import Data.Either (fromLeft, fromRight)
import qualified Data.Text as Text
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.State.Strict (evalStateT, execStateT, runStateT)
import Control.Monad.Trans (lift, liftIO)

import System.Environment
import System.Exit
import System.FilePath

import Debug.Trace


-- Try to handle implict/explict arguments. The whole '{a : Set}' thing.
-- It's somewhat done. Probably not correct yet but working

-- The '{a : A}' is a definition of a implicit function space.
-- To give an implicit argument explicit to a function, enclose it in brackets.

-- TODO Add comments to the Agda concrete syntax

-- There seems to be no information in the Idris AST about implicit
-- arguments. Which probably is to be expected at this stage before type
-- checking. Do I need to run elaboration/typechecking before being able to
-- generate correct Agda? Agda is much more demanding about these things.

-- TODO Handle parameterized Datatypes.
-- TODO Handle indexed Datatypes.
-- The parameters are required to be the same for all constructors, but indices
-- vary. In 'data Vector (A : Set) : Nat → Set where', 'A' is parameter and
-- 'Nat' a index. Parameters are bound once for all constructors, indices are
-- bound locally for each constructor. (In Agda)

-- Idris doesn't syntactically differentiate between indices and parameters,
-- while Agda does. I wonder when Idris computes that information? Because I
-- need that to generate correct Agda.

-- Instance arguments, is another thing I don't know well. They are solved by a
-- special instance resolution algorithm. Normal implicit arguments are solved
-- by unification. Instance arguments are similar to Haskell's type class
-- constraints. They are enclodsed in double brackets '{{ a : Show }}'

itaDecls :: [PDecl] -> [Declaration]
itaDecls pd = concat $ map itaDecl pd

itaDecl :: PDecl -> [Declaration]
-- TODO Add the Agda {a : Set} argument declaration
itaDecl (PData doc names synInfo range types
          (PDatadecl nameIdr _ typeconstructor dataconstructors)) =
    [Data range induc name lbBind expr typesigs]
  where range = NoRange
        induc = Inductive -- Inductive | CoInductive
        name = itaName nameIdr
        lbBind = [
          DomainFull (TBind NoRange [] (lit 333)) -- TODO This is not correct.
                 ]
        expr = itaTerm typeconstructor
        typesigs = map itaDC dataconstructors
-- TODO Preserve arg names.
itaDecl (PTy doc names synInfo range fnopts nameIdr rangeName terms) = -- Type declaration
  [typesig (itaName nameIdr) (itaTerm terms)]
itaDecl (PClauses range fnopts name clauses) = -- Pattern clause
  itaClauses clauses
itaDecl (PFix fc fixIdr strings) = [Infix fixAgda (map Main.mkName strings)]
  where fixAgda = itaFixity fixIdr
itaDecl _ = undefined

-- | Translate Data Constructors
itaDC :: ( Docstring (Either TT.Err PTerm)
         , [(TT.Name, Docstring (Either TT.Err PTerm))]
         , TT.Name
         , TT.FC
         , PTerm
         , TT.FC
         , [TT.Name]) -> TypeSignature
itaDC (doc, _, name, fc1, body, fc2, _) = typesig (itaName name) (itaTerm body)

-- TODO Properly display infix operators in the Agda AST.
itaFixity :: Idris.AbsSyntax.Fixity -> Agda.Syntax.Fixity.Fixity
itaFixity (Infixl prec) = Fixity NoRange (Related (toInteger prec)) LeftAssoc
itaFixity (Infixr prec) = Fixity NoRange (Related (toInteger prec)) RightAssoc
itaFixity (InfixN prec) = Fixity NoRange (Related (toInteger prec)) NonAssoc
itaFixity (PrefixN prec) = undefined -- I don't know that this is.

itaClauses :: [PClause] -> [Declaration]
itaClauses clauses = map itaClause clauses
  -- case length clauses of
  -- 1 -> itaClause $ head clauses -- Safe because of the case stmt.
  -- _ -> error ("PClause " ++ (show clauses)) -- When several pattern clauses

itaClause :: PClause -> Declaration
itaClause (PClause fc name whole with rhsIdr whrIdr) =
    FunClause lhs rhs whr bool
  where lhs = LHS ptn rewriteExpr withExpr
        rhs = RHS rhsexp -- Can also be 'AbsurdRHS'
        whr = NoWhere -- Can also be 'AnyWhere [Decls]'
        bool = False
        rhsexp = itaTerm rhsIdr
  -- TODO Research Problem
  -- This does not work for general patterns
  -- But I talked about skipping dependent patterns in the planning report.
  -- The LHS in Agda is represented as a 'Pattern'-type while it's a simple
  -- 'PTerm' in Idris. It's not obvious how to convert betwen them.
        ptn = itaPattern 0 whole
        rewriteExpr = []
        withExpr = []
itaClause (PWith _ _ _ _ _ _ _) = undefined
itaClause (PClauseR _ _ _ _) = undefined
itaClause (PWithR _ _ _ _ _) = undefined

-- The depth parameter is used to put parenthesis only when needed.
-- This is a ugly hack which should be redone.
-- We probably should retain the parenthesis placement from Idris, but I don't
-- think that's posssible
itaPattern :: Int -> PTerm -> Pattern
itaPattern _ (PRef _ _ name) = IdentP $ qname $ Main.prettyName name
-- With the simple parenthesis hack. This should be done correctly soon.
itaPattern 0 (PApp range fst args) =
    (RawAppP NoRange ((itaPattern 1 fst) : (map ((itaPattern 1) . itaArgsToTerm) args)))
itaPattern d (PApp range fst args) = ParenP NoRange
    (RawAppP
      NoRange
      ((itaPattern (d + 1) fst) : (map ((itaPattern (d + 1)) . itaArgsToTerm) args)))

itaArgsToTerm :: PArg -> PTerm
itaArgsToTerm (PExp prio argopts pname getTm) = getTm
itaArgsToTerm _ = undefined

application :: Expr -> [Expr] -> Expr
application head args = RawApp NoRange (head : args)

paren :: Expr -> Expr
paren e = Paren NoRange e
-- Parenthesis are explicit in the concrete Agda AST but are not represented in
-- the Idris PDecl lang. So that information is lost. I need to reconstruct that
-- somehow to get the output to typecheck. It is certainly possible to do with a
-- post-processing pass. But the output won't match the input. And how hard is
-- it to do correctly?
-- Right now there is this ugly hack.

createTelescope :: TT.Name -> PTerm -> Telescope
createTelescope name pterm = [TBind NoRange bargs (itaTerm pterm)]
  where bargs = [barg]
        barg = hiddenArg name (mkBoundName_ (itaName name))

-- data ArgOpt = AlwaysShow
--             | HideDisplay
--             | InaccessibleArg
--             | UnknownImp
-- data Static = Static | Dynamic
-- data RigCount = Rig0 | Rig1 | RigW
  -- Rig = Quantity?
itaPi :: Plicity -> TT.Name -> PTerm -> PTerm -> Expr
itaPi (Exp pargopts pstatic pparam pcount) name term1 term2 =
  -- There is something with name...
  -- trace ((show pargopts) ++ (show name) ++ (show pstatic) ++ (show pparam) ++ (show pcount))
  if isMN name then
    Fun NoRange (Arg defaultArgInfo (itaTerm term1))  (itaTerm term2)
  else
  case Main.prettyName name of
    -- TODO For some reason the Idris parser sets the names of some things
    -- It calls arguments __pi_arg.
    "__pi_arg" -> Fun NoRange (Arg defaultArgInfo (itaTerm term1))  (itaTerm term2)
    _ -> Pi (createTelescope name term1) (itaTerm term2)
  -- Fun NoRange (Arg defaultArgInfo (itaTerm term1))  (itaTerm term2)
  -- Pi (createTelescope name term1) (itaTerm term2)
itaPi q@(Imp pargopts pstatic pparam pscoped pinsource pcount) name term1 term2 =
  -- Fun NoRange (hiddenArg name (itaTerm term1))  (itaTerm term2)
  Pi (createTelescope name term1) (itaTerm term2)
 -- error ("itaPi: Imp problem with " ++ show name ++ show term1 ++ show term2)

itaPi (Constraint _ _ _) name term1 term2 = undefined
itaPi (TacImp _ _ _ _) name term1 term2 =  undefined

  -- TODO Type classes are implemented very differently in Agda. I probably wont do this.
{- example of parse of |{n : N} -> test n|
 Imp { pargopts = [],
       pstatic = Dynamic,
       pparam = False,
       pscoped = Just (Impl { tcimplementation = False,
                              toplevel_imp = True,
                              machine_gen = False}),
       pinsource = True,
       pcount = RigW
     }
-}

defaultArgInfoHidden :: ArgInfo
defaultArgInfoHidden =  ArgInfo
  { argInfoHiding        = Hidden
  , argInfoModality      = defaultModality
  , argInfoOrigin        = UserWritten
  , argInfoFreeVariables = UnknownFVs
  }


itaTerm :: PTerm -> Expr
itaTerm (PRef range highlightRange name) = iden $ Main.prettyName name
itaTerm whole@(PApp range fst args) = itaApp whole 0
itaTerm (PPi plicity name fc term1 term2) = itaPi plicity name term1 term2
itaTerm (PConstSugar fc term) = itaTerm term
itaTerm (PConstant fc const) = Lit (itaConst const)
itaTerm (PAlternative namePair alttype terms) = case length terms of
  1 -> itaTerm $ head terms -- Safe because of case stmt.
  0 -> undefined
  _ -> itaTerm $ head terms -- TODO Probably wrong. But it's safe at least
itaTerm (PType fc) = iden "Set"
itaTerm (PIfThenElse fc ift thent elset) = undefined
itaTerm (PPair fc fcs puninfo termA termB) = undefined
  -- This should return a hole.
itaTerm (PMetavar _ _) = hole "Comment"
itaTerm _ = undefined

-- Hack for 'fromInteger'
-- Deep pattern matching is bad form. But this is a ugly hack any way.
-- This seems to work but is ugly. Should be done in a pre-processing step to
-- remove all Idris quirks.
-- Also puts a pair of parenthesis around repeated function applications.
itaApp :: PTerm -> Int -> Expr
itaApp (PApp range fst@(PRef _ _ name) args) depth =
  if (Main.prettyName name) == "fromInteger"
  then head $ (map (itaArgs 0) args)
  else case depth of
    0 -> RawApp NoRange ((itaTerm fst) : (map (itaArgs 1) args))
    d -> paren $ RawApp NoRange ((itaTerm fst) : (map (itaArgs d) args))

itaConst :: TT.Const -> Literal
itaConst (TT.I int) = LitNat NoRange (toInteger int)
itaConst (TT.BI integer) = LitNat NoRange integer
itaConst (TT.Fl double) = LitFloat NoRange double
itaConst (TT.Ch char) = LitChar NoRange char
itaConst (TT.Str string) = LitString NoRange string
itaConst (TT.B8 word8) = undefined
itaConst (TT.B16 word16) = undefined
itaConst (TT.B32 word32) = undefined
itaConst (TT.B64 word64) = undefined
itaConst (TT.AType arithty) = itaAtype arithty
itaConst TT.StrType = undefined
itaConst TT.WorldType = undefined
itaConst TT.TheWorld = undefined
itaConst TT.VoidType = undefined
itaConst TT.Forgot = undefined

-- Arithmethic types?
-- Probably not. More like constants in types?
-- Or handles builtin types.
itaAtype :: TT.ArithTy -> Literal
itaAtype (TT.ATInt (TT.ITFixed nt)) = undefined
itaAtype (TT.ATInt TT.ITNative) = undefined
itaAtype (TT.ATInt TT.ITBig) = undefined
-- Char is a builtin type in Idris.
-- itaAtype (TT.ATInt TT.ITChar) = undefined
itaAtype (TT.ATInt TT.ITChar) = LitQName NoRange
  (AAbstract.QName (AAbstract.MName []) charName)
  where charName =
         AAbstract.Name { AAbstract.nameId          = NameId 1 1
                        , AAbstract.nameConcrete    = Main.mkName "Char"
                        , AAbstract.nameBindingSite = NoRange
                        , AAbstract.nameFixity      = mkFixity
                        , AAbstract.nameIsRecordName = False
                        }
itaAtype (TT.ATFloat) = undefined

itaName :: TT.Name -> Name
-- itaName n = Main.mkName $ Main.prettyName n
itaName n = Main.mkName $ show n

-- TODO This is not strictly correct. But for 'RawApp' which only take Exprs as
-- args it's okay
-- type PArg = PArg' PTerm -- getTm :: PTerm
-- This also has the depth hack to make sure we only put parenthesis when needed.
-- But the logic is probably not correct
itaArgs :: Int -> PArg -> Expr
itaArgs depth (PExp prio argopts pname getTm) =
  if (isPApp getTm)
     then itaApp getTm depth
     else itaTerm getTm
itaArgs _ _ = undefined

isPApp :: PTerm -> Bool
isPApp (PApp _ _ _) = True
isPApp _ = False

addComment = (++)
  -- There is also AbsStyntaxTree.prettyName but it's harder to use.
prettyName :: TT.Name -> String
prettyName (TT.UN name) =  Text.unpack name
prettyName (TT.MN id name) =  addComment
  ("Machine chosen name with id: " ++ (show id)) $ Text.unpack name
prettyName (TT.NS ns names) = concat $ intersperse "." $
  (map Text.unpack names) ++ [Main.prettyName ns]
  -- Names similar to "_t_0" are machine generated
-- prettyName (TT.SN sn) = addComment "Decorated function name" $ prettySN sn
-- prettyName (TT.SymRef id) = addComment "Reference to IBC" $ show id
prettyName _ = undefined

isMN :: TT.Name -> Bool
isMN (TT.MN _ _) = True
isMN _ = False

prettySN :: TT.SpecialName -> String
prettySN (TT.WhereN a b c) = "WhereN"
prettySN (TT.WithN a b) = "WithN"
prettySN (TT.ImplementationN a b) = "ImplementationN"
prettySN (TT.ParentN a b) = "ParentN"
prettySN (TT.MethodN a) = "MethodN"
prettySN (TT.CaseN a b) = "CaseN"
prettySN (TT.ImplementationCtorN a) = "ImplementationCtorN"
prettySN (TT.MetaN a b) = "MetaN"



--------------------------------------------------------------------------------
-- Command line interface

main :: IO ()
main = getArgs >>= parse >>= runITA

parse :: [String] -> IO (FilePath, Maybe FilePath)
parse ["-h"] = usage >> exit
parse ["-v"] = version >> exit
parse [] = usage >> exit
parse ["-o", outfile, infile] = return (infile, Just outfile)
parse [infile] = return (infile, Nothing)

usage = putStrLn "Usage: ita [-vh] [-o outfile.agda] [infile.idr]"
version = putStrLn "IdrisToAgda 0.1"
exit = exitWith ExitSuccess
die = exitWith (ExitFailure 1)
success outfile =
  putStrLn ("Successfuly compiled. Output written to: " ++ outfile) >> exit
errorMsg :: FilePath -> ParseError -> IO ()
errorMsg infile err =
  putStrLn ("Error while compiling file: " ++ infile ++ "\n\n" ++
            (prettyError err)) >> Main.die

runITA :: (FilePath, Maybe FilePath) -> IO ()
runITA (infile, outfile) =
  do out <- tryCompile infile
     case out of
       Left err -> print err
       Right res -> case outfile of
         Just outfilename -> writeFile outfilename res >> success outfilename
         Nothing -> putStrLn res

-- parseIdr :: (FilePath, Maybe FilePath) -> IO ()
-- parseIdr (infile, outfile) = do
--   ast <- runIdr $ parseF infile
--   case ast of
--       Left err -> putStrLn $ show err
--       Right pd -> case outfile of
--         Just out -> writeFile out (statsToCSV $ countD pd) >> success out
--         Nothing -> putStrLn $ showStats $ countD pd

-- Use `loadSource` and the real Idris impl, to use elaborated terms and so on.

-- 'itaDecl' is the function which does the translation.
tryCompile :: FilePath -> IO (Either TT.Err String)
tryCompile filename = do
  res <- runIdr $ parseF filename
  case res of
    Left err -> return $ Left err
    Right pd -> return $ Right $ prettyShow $ map itaDecl pd


--------------------------------------------------------------------------------
-- Test interface for implementation

test = do res <- runIdr $ parseF f
          case res of
              Right pd -> putStrLn $ prettyShow $ map itaDecl pd
              Left err -> putStrLn $ show err
  -- where f = "Blodwen/src/Core/Primitives.idr"
  -- where f = "../IdrisLibs/SequentialDecisionProblems/CoreTheory.lidr"
  -- where f = "Idris-dev/test/basic001/basic001a.idr"
  -- where f = "Idris-dev/libs/prelude/Prelude/Algebra.idr"
  -- where f = "Idris-dev/test/basic003/test027.idr "
  -- where f = "simpleIdris.idr"
  -- where f = "patrik.idr" -- [working 2019-08-15]
  where f = "testImp.idr"

getDefinitions c = Map.keys $ definitions c

parseF :: FilePath -> Idris [PDecl]
parseF f = do
        -- Load StdLib
        elabPrims
        addPkgDir "prelude"
        addPkgDir "base"
        loadModule "Builtins" (IBC_REPL False)
        addAutoImport "Builtins"
        loadModule "Prelude" (IBC_REPL False)
        addAutoImport "Prelude"
        -- TODO
        -- I probably need to load the current directory as well. And maybe the
        -- whole project structure
        loadModule f $ IBC_REPL True

        i <- getIState
        -- liftIO $ putStrLn $ showStats $ countD (ast i)
  -- TODO START HERE
  -- Also return the elaboration info.
        -- liftIO (putStrLn $ show $ getDefinitions $ tt_ctxt i)
        let t = definitions $ tt_ctxt i
        let names = Map.keys t
        let concatName = TT.sUN "concat"
        let concat = ttLookup concatName t
        let ty = getDef (Maybe.fromJust concat)
        iPrint concat
        let ttty = Maybe.fromJust $ getTTType ty
        sig <- liftIO (tttExpr ttty)
        -- liftIO (putStrLn $ show ttty)
        iPrint ttty
        liftIO (putStrLn "Agda:")
        liftIO (agda sig)

        return (ast i)
  where addPkgDir :: String -> Idris ()
        addPkgDir p = do ddir <- runIO getIdrisLibDir
                         addImportDir (ddir </> p)
                         addIBC (IBCImportDir (ddir </> p))

-- runIdr :: Idris a -> IO (Either TT.Err IState)
-- runIdr prog = runExceptT $ execStateT prog idrisInit
iPrint a = liftIO (print a)
  
runIdr :: Idris a -> IO (Either TT.Err a)
runIdr a = runExceptT (evalStateT a idrisInit)

testElab decls = runIdr $ elabDecls elabinfo decls
  where elabinfo = toplevel

agda d = putStrLn $ prettyShow d

-- Test functions while developing
tp = do (file :: String) <- readSource f
        let res = testParse file
        case res of
          Left err -> putStrLn $ prettyError err
          Right pd -> do
            putStrLn "PDecls:"
            putPDecls pd
            putStrLn "\nAgda:"
            (putStrLn $ show $ map itaDecl pd)
            putStrLn "\nOutput:"
            putStrLn $ prettyShow $ map itaDecl pd
          -- Right pd -> putStrLn $ prettyShow $ map itaDecl pd
          -- Right pd -> putPDecls pd
  -- where f = "patrik.idr"
  -- where f = "testP.idr"
  where f = "testF.idr"
        putPDecls lst = putStrLn $ concat $ intersperse "\n\n" $ map show lst

-- te :: IO (Either TT.Err IState)
-- te :: IO ()
-- te = do (file :: String) <- readSource f
--         let q = testParse file
--         let w = fromRight [] q
--         e <- elab w
--         -- do w <- elab q
--         --    return w
--         -- w <- elab q
--           -- left err -> putstrln $ prettyerror err
--           -- right pd -> testelab pd
--         let r = fromRight undefined e
--         let t = definitions $ tt_ctxt r
--         let names = Map.keys t
--         let concatName = TT.sUN "concat"
--         let concat = ttLookup concatName t
--         let ty = getDef concat
--         let ttty = Maybe.fromJust $ getTTType ty
--         sig <- tttExpr ttty
--         putStrLn $ show ttty
--         putStrLn "Agda:"
--         agda sig
--         -- return r
--     where f = "simpleIdris.idr"
--           elab pdecl = liftIO (testElab pdecl)
--           parseErr e = putStrLn $ prettyError e
  -- tt_ctxt on IState is a good guess
  -- Returns a `Context` which has a field `definitions :: Context -> Ctxt TTDecl`

ttLookup :: TT.Name -> TT.Ctxt TTDecl -> Maybe TTDecl
ttLookup name ctxt = (Map.lookup name (Maybe.fromJust (Map.lookup name ctxt)))

getDef :: TTDecl -> Def
getDef (def, _, _, _, _, _)  = def

getTTType :: Def -> Maybe TT.Type
getTTType (TyDecl nametype ty) = Just ty
getTTType _ = Nothing

tttExpr :: TT.Type -> IO Expr
tttExpr (TT.P nametype n tt) = do putStrLn $ "P " ++ show n
                                  tttExpr tt
tttExpr (TT.V i) = do putStrLn $ "V " ++ (show i)
                      return (lit $ fromIntegral i)
tttExpr (TT.Bind n binder tt) = do putStrLn $ "Bind " ++ show n
                                   tttaBind n binder tt
                                   -- tttExpr tt
tttExpr (TT.App appstatus tt1 tt2) = do putStrLn "App"
                                        a <- tttExpr tt1
                                        b <- tttExpr tt2
                                        return $ application a [b]

tttExpr (TT.Constant const) = undefined
tttExpr (TT.Proj tt i) = undefined
tttExpr (TT.Erased) = undefined
tttExpr (TT.Impossible) = undefined
tttExpr (TT.Inferred tt) = undefined
tttExpr t@(TT.TType uexp) = do putStrLn $ "TType" ++ (show uexp)
                               return (iden $ show uexp)
tttExpr (TT.UType universe) = undefined
  
itaTTNameType :: TT.NameType -> Name
itaTTNameType (TT.Ref) = undefined
itaTTNameType _ = undefined

impl :: TT.ImplicitInfo -> Bool
impl (TT.Impl tc toplevel machine_gen) = toplevel

  -- | HiddenArg Range (Named_ Expr)              -- ^ ex: @{e}@ or @{x=e}@
tttaBind :: TT.Name -> TT.Binder (TT.Term) -> TT.Term -> IO Expr
tttaBind name b@(TT.Pi rigCount implI ty kind) term =
  do putStrLn $ "Binder: "  ++ (show b)
     putStrLn $ show (itaName name)
     putStrLn $ show (name)
     -- putStrLn $ show ty
     -- putStrLn "Binder term:"
     -- putStrLn $ show term
     -- putStrLn "End Binder"
     t <- tttExpr ty
     ter <- tttExpr term
     case implI of
       Just _ -> return (Fun NoRange (Arg argInfo (hiddenArg (itaName name) t)) ter)
       Nothing -> return (Fun NoRange (Arg argInfo t) ter)
  -- Fun NoRange (Arg argInfo (itaTerm term1)) (itaTerm term2)
  where argInfo = (ArgInfo NotHidden defaultModality UserWritten UnknownFVs)
tttaBind _ _ _ = undefined


testParse p = runparser (prog defaultSyntax) idrisInit "(test)" p

--------------------------------------------------------------------------------
-- Agda constructors

mkName :: String -> Name
mkName n = Name NoRange InScope [(Id n)]
qname :: String -> QName
qname n = QName $ Main.mkName n

iden n = Ident $ qname n

lit :: Integer -> Expr
lit i = Lit $ LitNat NoRange i

modality :: Modality
modality = Modality Relevant defaultQuantity
-- modality = Modality Relevant Quantity0
-- defaultModality = Modality defaultRelevance defaultQuantity

arg :: String -> a -> NamedArg a
arg name expr
  -- TODO Should there be a special case for "__pi_arg"?
  | name == "__pi_arg" = defaultNamedArg expr
  | otherwise = Arg (ArgInfo NotHidden modality UserWritten UnknownFVs) $
  Named (Just (Ranged NoRange name)) expr

  -- Only hidden arguments can have names in Agda
-- hiddenArg :: String -> a -> NamedArg a
-- hiddenArg name expr = Arg (ArgInfo Hidden modality UserWritten UnknownFVs) $
--   Named (Just (Ranged NoRange name)) expr

-- type Named_ = Named RString
  -- | HiddenArg Range (Named_ Expr)              -- ^ ex: @{e}@ or @{x=e}@
hiddenArg :: Name -> Expr -> Expr
hiddenArg n e = HiddenArg NoRange name
  where name = Named (Just (Ranged NoRange (prettyShow n))) e

funcExpr :: String -> Expr -> Expr
funcExpr name body = Fun NoRange (Arg argInfo (iden name)) body
  where argInfo = (ArgInfo NotHidden modality UserWritten UnknownFVs)

hole :: String -> Expr
hole comment = QuestionMark NoRange Nothing

typesig :: Name -> Expr -> TypeSignature
typesig name body = TypeSig argInfo name body
  where argInfo = ArgInfo NotHidden modality UserWritten UnknownFVs
        expr = funcExpr "argTest" (iden "FunctionTest")

mkFixity :: Fixity'
mkFixity = Fixity' f not NoRange
  where f = Fixity NoRange Unrelated NonAssoc
        rstring = Ranged NoRange "RawName"
        not = [IdPart rstring]
