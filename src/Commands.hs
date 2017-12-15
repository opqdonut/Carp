module Commands where

import Parsing
import Emit
import Obj
import Types
import Infer
import Deftype
import ColorText
import Template
import Util
import System.Directory
import System.Info (os)
import Control.Monad.State
import Control.Monad.State.Lazy (StateT(..), runStateT, liftIO, modify, get, put)
import System.Exit (exitSuccess, exitFailure, exitWith, ExitCode(..))
import qualified Data.Map as Map
import System.Process (callCommand, spawnCommand, waitForProcess)
import Control.Exception

type CommandCallback = [XObj] -> StateT Context IO (Either EvalError XObj)

data CarpException =
    ShellOutException { shellOutMessage :: String, returnCode :: Int }
  | CancelEvaluationException
  deriving (Eq, Show)

instance Exception CarpException

dynamicNil :: Either a XObj
dynamicNil = Right (XObj (Lst []) (Just dummyInfo) (Just UnitTy)) -- TODO: Remove/unwrap (Right ...) to a XObj

addCommand :: String -> CommandFunctionType -> (String, Binder)
addCommand name callback =
  let path = SymPath [] name
      cmd = XObj (Lst [XObj (Command callback) (Just dummyInfo) Nothing
                      ,XObj (Sym path) Nothing Nothing
                      ])
            (Just dummyInfo) (Just DynamicTy)
  in (name, Binder cmd)

commandQuit :: CommandCallback
commandQuit args =
  do liftIO exitSuccess
     return dynamicNil

commandCat :: CommandCallback
commandCat args =
  do ctx <- get
     let outDir = projectOutDir (contextProj ctx)
         outMain = outDir ++ "main.c"
     liftIO $ do callCommand ("cat -n " ++ outMain)
                 return dynamicNil

commandRunExe :: CommandCallback
commandRunExe args =
  do ctx <- get
     let outDir = projectOutDir (contextProj ctx)
         outExe = outDir ++ "a.out"
     liftIO $ do handle <- spawnCommand outExe
                 exitCode <- waitForProcess handle
                 case exitCode of
                   ExitSuccess -> return (Right (XObj (Num IntTy 0) (Just dummyInfo) (Just IntTy)))
                   ExitFailure i -> throw (ShellOutException ("'" ++ outExe ++ "' exited with return value " ++ show i ++ ".") i)

commandBuild :: CommandCallback
commandBuild args =
  do ctx <- get
     let env = contextGlobalEnv ctx
         typeEnv = contextTypeEnv ctx
         proj = contextProj ctx
         execMode = contextExecMode ctx
         src = do decl <- envToDeclarations typeEnv env
                  typeDecl <- envToDeclarations typeEnv (getTypeEnv typeEnv)
                  c <- envToC env
                  return ("//Types:\n" ++ typeDecl ++ "\n\n//Declarations:\n" ++ decl ++ "\n\n//Definitions:\n" ++ c)
     case src of
       Left err ->
         liftIO $ do putStrLnWithColor Red ("[CODEGEN ERROR] " ++ show err)
                     return dynamicNil
       Right okSrc ->
         liftIO $ do let compiler = projectCompiler proj
                         echoCompilationCommand = projectEchoCompilationCommand proj
                         incl = projectIncludesToC proj
                         includeCorePath = " -I" ++ projectCarpDir proj ++ "/core/ "
                         switches = " -g "
                         flags = projectFlags proj ++ includeCorePath ++ switches
                         outDir = projectOutDir proj
                         outMain = outDir ++ "main.c"
                         outExe = outDir ++ "a.out"
                         outLib = outDir ++ "lib.so"
                     createDirectoryIfMissing False outDir
                     writeFile outMain (incl ++ okSrc)
                     case Map.lookup "main" (envBindings env) of
                       Just _ -> do let cmd = compiler ++ " " ++ outMain ++ " -o " ++ outExe ++ " " ++ flags
                                    when echoCompilationCommand (putStrLn cmd)
                                    callCommand cmd
                                    when (execMode == Repl) (putStrLn ("Compiled to '" ++ outExe ++ "'"))
                                    return dynamicNil
                       Nothing -> do let cmd = compiler ++ " " ++ outMain ++ " -shared -o " ++ outLib ++ " " ++ flags
                                     when echoCompilationCommand (putStrLn cmd)
                                     callCommand cmd
                                     when (execMode == Repl) (putStrLn ("Compiled to '" ++ outLib ++ "'"))
                                     return dynamicNil

commandListBindings :: CommandCallback
commandListBindings args =
  do ctx <- get
     liftIO $ do putStrLn "Types:\n"
                 putStrLn (prettyEnvironment (getTypeEnv (contextTypeEnv ctx)))
                 putStrLn "\nGlobal environment:\n"
                 putStrLn (prettyEnvironment (contextGlobalEnv ctx))
                 putStrLn ""
                 return dynamicNil

commandHelp :: CommandCallback

commandHelp [XObj (Sym (SymPath [] "about")) _ _] =
  liftIO $ do putStrLn "Carp is an ongoing research project by Erik Svedäng, et al."
              putStrLn ""
              putStrLn "Licensed under the Apache License, Version 2.0 (the \"License\"); \n\
                       \you may not use this file except in compliance with the License. \n\
                       \You may obtain a copy of the License at \n\
                       \http://www.apache.org/licenses/LICENSE-2.0"
              putStrLn ""
              putStrLn "THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY \n\
                       \EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \n\
                       \IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR \n\
                       \PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE \n\
                       \LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \n\
                       \CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF \n\
                       \SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR \n\
                       \BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, \n\
                       \WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE \n\
                       \OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN\n\
                       \IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "language")) _ _] =
  liftIO $ do putStrLn "Special forms:"
              putStrLn "(if <condition> <then> <else>)"
              putStrLn "(while <condition> <body>)"
              putStrLn "(do <statement1> <statement2> ... <exprN>)"
              putStrLn "(let [<sym1> <expr1> <name2> <expr2> ...] <body>)"
              --putStrLn "(fn [<args>] <body>)"
              putStrLn "(the <type> <expression>)"
              putStrLn "(ref <expression>)"
              putStrLn "(address <expr>)"
              putStrLn "(set! <var> <value>)"
              putStrLn ""
              putStrLn "To use functions in modules without qualifying them:"
              putStrLn "(use <module>)"
              putStrLn ""
              putStrLn ("Valid non-alphanumerics: " ++ validCharacters)
              putStrLn ""
              putStrLn "Number literals:"
              putStrLn "1      Int"
              putStrLn "1l     Int"
              putStrLn "1.0    Double"
              putStrLn "1.0f   Float"
              putStrLn ""
              putStrLn "Reader macros:"
              putStrLn "&<expr>   (ref <expr>)"
              putStrLn "@<expr>   (copy <expr>)"
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "macros")) _ _] =
  liftIO $ do putStrLn "Some useful macros:"
              putStrLn "(cond <condition1> <expr1> ... <else-condition>)"
              putStrLn "(for [<var> <from> <to>] <body>)"
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "structs")) _ _] =
  liftIO $ do putStrLn "A type definition will generate the following methods:"
              putStrLn "Getters  (<method-name> (Ref <struct>))"
              putStrLn "Setters  (set-<method-name> <struct> <new-value>)"
              putStrLn "Updaters (update-<method-name> <struct> <new-value>)"
              putStrLn "init (stack allocation)"
              putStrLn "new (heap allocation)"
              putStrLn "copy"
              putStrLn "delete (used internally, no need to call this explicitly)"
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "shortcuts")) _ _] =
  liftIO $ do putStrLn "GHC-style shortcuts at the repl:"
              putStrLn "(reload)   :r"
              putStrLn "(build)    :b"
              putStrLn "(run)      :x"
              putStrLn "(cat)      :c"
              putStrLn "(env)      :e"
              putStrLn "(help)     :h"
              putStrLn "(project)  :p"
              putStrLn "(quit)     :q"
              putStrLn ""
              putStrLn "The shortcuts can be combined like this: \":rbx\""
              putStrLn ""
              return dynamicNil

commandHelp [] =
  liftIO $ do putStrLn "Compiler commands:"
              putStrLn "(load <file>)      - Load a .carp file, evaluate its content, and add it to the project."
              putStrLn "(reload)           - Reload all the project files."
              putStrLn "(build)            - Produce an executable or shared library."
              putStrLn "(run)              - Run the executable produced by 'build' (if available)."
              putStrLn "(cat)              - Look at the generated C code (make sure you build first)."
              putStrLn "(env)              - List the bindings in the global environment."
              putStrLn "(type <symbol>)    - Get the type of a binding."
              putStrLn "(info <symbol>)    - Get information about a binding."
              putStrLn "(project)          - Display information about your project."
              putStrLn "(quit)             - Terminate this Carp REPL."
              putStrLn "(help <chapter>)   - Available chapters: language, macros, structs, shortcuts, about."
              putStrLn ""
              putStrLn "To define things:"
              putStrLn "(def <name> <constant>)           - Define a global variable."
              putStrLn "(defn <name> [<args>] <body>)     - Define a function."
              putStrLn "(module <name> <def1> <def2> ...) - Define a module and/or add definitions to an existing one."
              putStrLn "(deftype <name> ...)              - Define a new type."
              putStrLn "(register <name> <type>)          - Make an external variable or function available for usage."
              putStrLn "(defalias <name> <type>)          - Create another name for a type."
              putStrLn ""
              putStrLn "C-compiler configuration:"
              putStrLn "(system-include <file>)          - Include a system header file."
              putStrLn "(local-include <file>)           - Include a local header file."
              putStrLn "(add-cflag <flag>)               - Add a cflag to the compilation step."
              putStrLn "(add-lib <flag>)                 - Add a library flag to the compilation step."
              putStrLn "(project-set! <setting> <value>) - Change a project setting (not fully implemented)."
              putStrLn ""
              putStrLn "Compiler flags:"
              putStrLn "-b                               - Build."
              putStrLn "-x                               - Build and run."
              return dynamicNil

commandHelp args =
  do liftIO $ putStrLn ("Can't find help for " ++ joinWithComma (map pretty args))
     return dynamicNil

commandProject :: CommandCallback
commandProject args =
  do ctx <- get
     liftIO (print (contextProj ctx))
     return dynamicNil

commandPrint :: CommandCallback
commandPrint args =
  do liftIO $ mapM_ (putStrLn . pretty) args
     return dynamicNil

commandOS :: CommandCallback
commandOS _ =
  return (Right (XObj (Str os) (Just dummyInfo) (Just StringTy)))

commandAddInclude :: (String -> Includer) -> CommandCallback
commandAddInclude includerConstructor [XObj (Str file) _ _] =
  do ctx <- get
     let proj = contextProj ctx
         includer = includerConstructor file
         includers = projectIncludes proj
         includers' = if includer `elem` includers
                      then includers
                      else includer : includers
         proj' = proj { projectIncludes = includers' }
     put (ctx { contextProj = proj' })
     return dynamicNil

commandAddSystemInclude = commandAddInclude SystemInclude
commandAddLocalInclude  = commandAddInclude LocalInclude

-- -- | This function will show the resulting code of non-definitions.
-- -- | i.e. (Int.+ 2 3) => "_0 = 2 + 3"
-- consumeExpr :: Context -> XObj -> IO ReplCommand
-- consumeExpr ctx@(Context globalEnv typeEnv _ _ _ _) xobj =
--   do (expansionResult, newCtx) <- runStateT (expandAll globalEnv xobj) ctx
--      case expansionResult of
--        Left err -> return (ReplMacroError (show err))
--        Right expanded ->
--          case annotate typeEnv globalEnv (setFullyQualifiedSymbols typeEnv globalEnv expanded) of
--            Left err -> return (ReplTypeError (show err))
--            Right annXObjs -> return (ListOfCallbacks (map printC annXObjs))

-- printC :: XObj -> CommandCallback
-- printC xobj =
--   case checkForUnresolvedSymbols xobj of
--     Left e ->
--       (const (commandPrint [(XObj (Str (strWithColor Red (show e ++ ", can't print resulting code.\n"))) Nothing Nothing)]))
--     Right _ ->
--       (const (commandPrint [(XObj (Str (strWithColor Green (toC xobj))) Nothing Nothing)]))
