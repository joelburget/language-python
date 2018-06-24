{-# OPTIONS  #-}
-----------------------------------------------------------------------------
-- |
-- Module      : Language.Python.Common.ParserUtils
-- Copyright   : (c) 2009 Bernie Pope
-- License     : BSD-style
-- Maintainer  : bjpop@csse.unimelb.edu.au
-- Stability   : experimental
-- Portability : ghc
--
-- Various utilities to support the Python parser.
-----------------------------------------------------------------------------

module Language.Python.Common.ParserUtils where

import Data.List (foldl')
import Data.Maybe (isJust)
import Control.Monad.Error.Class (throwError)
import Language.Python.Common.AST as AST
import Language.Python.Common.Token as Token
import Language.Python.Common.ParserMonad hiding (location)
import Language.Python.Common.SrcLocation

makeConditionalExpr :: ExprSpan -> Maybe (ExprSpan, ExprSpan) -> ExprSpan
makeConditionalExpr e Nothing = e
makeConditionalExpr e opt@(Just (cond, false_branch))
   = CondExpr e cond false_branch (spanning e opt)

makeBinOp :: ExprSpan -> [(OpSpan, ExprSpan)] -> ExprSpan
makeBinOp e es
   = foldl' mkOp e es
   where
   mkOp e1 (op, e2) = BinaryOp op e1 e2 (spanning e1 e2)

parseError :: Token -> P a
parseError = throwError . UnexpectedToken

data Trailer
   = TrailerCall { trailer_call_args :: [ArgumentSpan], trailer_span :: SrcSpan }
   | TrailerSubscript { trailer_subs :: [Subscript], trailer_span :: SrcSpan }
   | TrailerDot { trailer_dot_ident :: IdentSpan, dot_span :: SrcSpan, trailer_span :: SrcSpan }

instance Span Trailer where
  getSpan = trailer_span

data Subscript
   = SubscriptExpr { subscription :: ExprSpan, subscript_span :: SrcSpan }
   | SubscriptSlice
     { subscript_slice_span1 :: Maybe ExprSpan
     , subscript_slice_span2 :: Maybe ExprSpan
     , subscript_slice_span3 :: Maybe (Maybe ExprSpan)
     , subscript_span :: SrcSpan
     }
   | SubscriptSliceEllipsis { subscript_span :: SrcSpan }

instance Span Subscript where
   getSpan = subscript_span

isProperSlice :: Subscript -> Bool
isProperSlice (SubscriptSlice {}) = True
isProperSlice (SubscriptSliceEllipsis {}) = True
isProperSlice other = False

subscriptToSlice :: Subscript -> SliceSpan
subscriptToSlice (SubscriptSlice lower upper stride span)
   = SliceProper lower upper stride span
subscriptToSlice (SubscriptExpr e span)
   = SliceExpr e span
subscriptToSlice (SubscriptSliceEllipsis span)
   = SliceEllipsis span

subscriptToExpr :: Subscript -> ExprSpan
subscriptToExpr (SubscriptExpr { subscription = s }) = s
subscriptToExpr other = error "subscriptToExpr applied to non subscript"

subscriptsToExpr :: [Subscript] -> ExprSpan
subscriptsToExpr subs
   | length subs > 1 = Tuple (map subscriptToExpr subs) (getSpan subs)
   | length subs == 1 = subscriptToExpr $ head subs
   | otherwise = error "subscriptsToExpr: empty subscript list"

addTrailer :: ExprSpan -> [Trailer] -> ExprSpan
addTrailer
   = foldl' trail
   where
   trail :: ExprSpan -> Trailer -> ExprSpan
   -- XXX fix the span
   trail e trail@(TrailerCall { trailer_call_args = args }) = Call e args (spanning e trail)
   trail e trail@(TrailerSubscript { trailer_subs = subs })
      | any isProperSlice subs
           = SlicedExpr e (map subscriptToSlice subs) (spanning e trail)
      | otherwise
           = Subscript e (subscriptsToExpr subs) (spanning e trail)
   trail e trail@(TrailerDot { trailer_dot_ident = ident, dot_span = ds })
      = Dot { dot_expr = e, dot_attribute = ident, expr_annot = spanning e trail }

makeTupleOrExpr :: [ExprSpan] -> Maybe Token -> ExprSpan
makeTupleOrExpr [e] Nothing = e
makeTupleOrExpr es@(_:_) (Just t) = Tuple es (spanning es t)
makeTupleOrExpr es@(_:_) Nothing  = Tuple es (getSpan es)

makeNormalAssignment :: ExprSpan -> [ExprSpan] -> StatementSpan
makeNormalAssignment e [] = StmtExpr e (getSpan e)
makeNormalAssignment e es
  = AST.Assign (e : front) (head back) (spanning e es)
  where
  (front, back) = splitAt (len - 1) es
  len = length es

makeAnnAssignment :: ExprSpan -> (ExprSpan, Maybe ExprSpan) -> StatementSpan
makeAnnAssignment ato (annotation, ae) = AST.AnnotatedAssign annotation ato ae (spanning ae ato)

makeTry :: Token -> SuiteSpan -> ([HandlerSpan], [StatementSpan], [StatementSpan]) -> StatementSpan
makeTry t1 body (handlers, elses, finally)
   = AST.Try body handlers elses finally
     (spanning (spanning (spanning (spanning t1 body) handlers) elses) finally)

makeParam :: (IdentSpan, Maybe ExprSpan) -> Maybe ExprSpan -> ParameterSpan
makeParam (name, annot) defaultVal
   = Param name annot defaultVal paramSpan
   where
   paramSpan = spanning (spanning name annot) defaultVal

makeStarParam :: Token -> Maybe (IdentSpan, Maybe ExprSpan) -> ParameterSpan
makeStarParam t1 Nothing = EndPositional (getSpan t1)
makeStarParam t1 (Just (name, annot))
   = VarArgsPos name annot (spanning t1 annot)

makeStarStarParam :: Token -> (IdentSpan, Maybe ExprSpan) -> ParameterSpan
makeStarStarParam t1 (name, annot)
   = VarArgsKeyword name annot (spanning (spanning t1 name) annot)

-- version 2 only
makeTupleParam :: ParamTupleSpan -> Maybe ExprSpan -> ParameterSpan
-- just a name
makeTupleParam p@(ParamTupleName {}) optDefault =
   Param (param_tuple_name p) Nothing optDefault (spanning p optDefault)
-- a parenthesised tuple. NOTE: we do not distinguish between (foo) and (foo,)
makeTupleParam p@(ParamTuple { param_tuple_annot = span }) optDefault =
   UnPackTuple p optDefault span

makeComprehension :: ExprSpan -> CompForSpan -> ComprehensionSpan
makeComprehension e for = Comprehension (ComprehensionExpr e) for (spanning e for)

makeListForm :: SrcSpan -> Either ExprSpan ComprehensionSpan -> ExprSpan
makeListForm span (Left tuple@(Tuple {})) = List (tuple_exprs tuple) span
makeListForm span (Left other) = List [other] span
makeListForm span (Right comprehension) = ListComp comprehension span

makeSet :: ExprSpan -> Either CompForSpan [ExprSpan] -> SrcSpan -> ExprSpan
makeSet e (Left compFor) = SetComp (Comprehension (ComprehensionExpr e) compFor (spanning e compFor))
makeSet e (Right es) = Set (e:es)

-- The Either (ExprSpan, ExprSpan) ExprSpan refers to a (key, value) pair or a dictionary unpacking expression.
makeDictionary :: Either (ExprSpan, ExprSpan) ExprSpan -> Either CompForSpan [Either (ExprSpan, ExprSpan) ExprSpan] -> SrcSpan -> ExprSpan
makeDictionary (Left mapping@(key, val)) (Left compFor) =
   DictComp (Comprehension (ComprehensionDict (DictMappingPair key val)) compFor (spanning mapping compFor))
-- This is allowed by the grammar, but will produce a runtime syntax error:
-- dict unpacking cannot be used in dict comprehension
makeDictionary (Right unpacking) (Left compFor) =
   DictComp (Comprehension (ComprehensionDict (DictUnpacking unpacking)) compFor (spanning unpacking compFor))
makeDictionary item (Right es) = Dictionary $ toKeyDatumList <$> item : es


toKeyDatumList :: Either (ExprSpan, ExprSpan) ExprSpan -> DictKeyDatumList SrcSpan
toKeyDatumList (Left (key, value)) = DictMappingPair key value
toKeyDatumList (Right unpacking) = DictUnpacking unpacking


fromEither :: Either a a -> a
fromEither (Left x) = x
fromEither (Right x) = x

makeDecorator :: Token -> DottedNameSpan -> [ArgumentSpan] -> DecoratorSpan
makeDecorator t1 name [] = Decorator name [] (spanning t1 name)
makeDecorator t1 name args = Decorator name args (spanning t1 args)

-- parser guarantees that the first list is non-empty
makeDecorated :: [DecoratorSpan] -> StatementSpan -> StatementSpan
makeDecorated ds@(d:_) def = Decorated ds def (spanning d def)

-- suite can't be empty so it is safe to take span over it
makeFun :: Token -> IdentSpan -> [ParameterSpan] -> Maybe ExprSpan -> SuiteSpan -> StatementSpan
makeFun t1 name params annot body =
   Fun name params annot body $ spanning t1 body

makeReturn :: Token -> Maybe ExprSpan -> StatementSpan
makeReturn t1 Nothing = AST.Return Nothing (getSpan t1)
makeReturn t1 expr@(Just e) = AST.Return expr (spanning t1 e)

makeParenOrGenerator :: Either ExprSpan ComprehensionSpan -> SrcSpan -> ExprSpan
makeParenOrGenerator (Left e) span = Paren e span
makeParenOrGenerator (Right comp) span = Generator comp span

{-
   See: http://docs.python.org/3.0/reference/expressions.html#calls

   arglist: (argument ',')* (argument [',']
                         |'*' test (',' argument)* [',' '**' test]
                         |'**' test)

   (state 1) Positional arguments come first.
   (state 2) Then keyword arguments.
   (state 3) Then the single star form.
   (state 4) Then more keyword arguments (but no positional arguments).
   (state 5) Then the double star form.

XXX fixme: we need to include SrcLocations for the errors.
-}

checkArguments :: [ArgumentSpan] -> P [ArgumentSpan]
checkArguments args = do
   check 1 args
   return args
   where
   check :: Int -> [ArgumentSpan] -> P ()
   check state [] = return ()
   check 5 (arg:_) = spanError arg "an **argument must not be followed by any other arguments"
   check state (arg:rest) = do
      case arg of
         ArgExpr {}
            | state == 1 -> check state rest
            | state == 2 -> spanError arg "a positional argument must not follow a keyword argument"
            | otherwise -> spanError arg "a positional argument must not follow a *argument"
         ArgKeyword {}
            | state `elem` [1,2] -> check 2 rest
            | state `elem` [3,4] -> check 4 rest
         ArgVarArgsPos {}
            | state `elem` [1,2] -> check 3 rest
            | state `elem` [3,4] -> spanError arg "there must not be two *arguments in an argument list"
         ArgVarArgsKeyword {} -> check 5 rest

{-
   See: http://docs.python.org/3.1/reference/compound_stmts.html#grammar-token-parameter_list

   parameter_list ::=  (defparameter ",")*
                    (  "*" [parameter] ("," defparameter)*
                    [, "**" parameter]
                    | "**" parameter
                    | defparameter [","] )

   (state 1) Parameters/unpack tuples first.
   (state 2) Then the single star (on its own or with parameter)
   (state 3) Then more parameters.
   (state 4) Then the double star form.

   XXX fixme, add support for version 2 unpack tuple.
-}

checkParameters :: [ParameterSpan] -> P [ParameterSpan]
checkParameters params = do
   check 1 params
   return params
   where
   check :: Int -> [ParameterSpan] -> P ()
   check state [] = return ()
   check 4 (param:_) = spanError param "a **parameter must not be followed by any other parameters"
   check state (param:rest) = do
      case param of
         -- Param and UnPackTuple are treated the same.
         UnPackTuple {}
            | state `elem` [1,3] -> check state rest
            | state == 2 -> check 3 rest
         Param {}
            | state `elem` [1,3] -> check state rest
            | state == 2 -> check 3 rest
         EndPositional {}
            | state == 1 -> check 2 rest
            | otherwise -> spanError param "there must not be two *parameters in a parameter list"
         VarArgsPos {}
            | state == 1 -> check 2 rest
            | otherwise -> spanError param "there must not be two *parameters in a parameter list"
         VarArgsKeyword {} -> check 4 rest

{-
spanError :: Span a => a -> String -> P ()
spanError x str = throwError $ StrError $ unwords [prettyText $ getSpan x, str]
-}
