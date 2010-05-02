-- | Efficient generation of JSON documents, with HTML-entity encoding handled via types.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}
module Yesod.Json
    ( -- * Monad
      Json
    , jsonToContent
      -- * Generate Json output
    , jsonScalar
    , jsonList
    , jsonList'
    , jsonMap
    , jsonMap'
#if TEST
    , testSuite
#endif
    )
    where

import Text.Hamlet.Monad
import Control.Applicative
import Data.Text (Text, pack)
import Web.Encodings
import Yesod.Hamlet
import Yesod.Definitions
import Control.Monad (when)
import Yesod.Handler
import Yesod.Content

#if TEST
import Test.Framework (testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.HUnit hiding (Test)
import Data.Text.Lazy (unpack)
#endif

-- | A monad for generating Json output. In truth, it is just a newtype wrapper
-- around 'Hamlet'; we thereby get the benefits of Hamlet (interleaving IO and
-- enumerator output) without accidently mixing non-JSON content.
--
-- This is an opaque type to avoid any possible insertion of non-JSON content.
-- Due to the limited nature of the JSON format, you can create any valid JSON
-- document you wish using only 'jsonScalar', 'jsonList' and 'jsonMap'.
newtype Json url a = Json { unJson :: Hamlet url IO a }
    deriving (Functor, Applicative, Monad)

-- | Extract the final result from the given 'Json' value.
--
-- See also: applyLayoutJson in "Yesod.Yesod".
jsonToContent :: Json (Routes master) () -> GHandler sub master Content
jsonToContent = hamletToContent . unJson

htmlContentToText :: HtmlContent -> Text
htmlContentToText (Encoded t) = t
htmlContentToText (Unencoded t) = encodeHtml t

-- | Outputs a single scalar. This function essentially:
--
-- * Performs HTML entity escaping as necesary.
--
-- * Performs JSON encoding.
--
-- * Wraps the resulting string in quotes.
jsonScalar :: HtmlContent -> Json url ()
jsonScalar s = Json $ do
    outputString "\""
    output $ encodeJson $ htmlContentToText s
    outputString "\""

-- | Outputs a JSON list, eg [\"foo\",\"bar\",\"baz\"].
jsonList :: [Json url ()] -> Json url ()
jsonList = jsonList' . fromList

-- | Same as 'jsonList', but uses an 'Enumerator' for input.
jsonList' :: Enumerator (Json url ()) (Json url) -> Json url () -- FIXME simplify type
jsonList' (Enumerator enum) = do
    Json $ outputString "["
    _ <- enum go False
    Json $ outputString "]"
  where
    go putComma j = do
        when putComma $ Json $ outputString ","
        () <- j
        return $ Right True

-- | Outputs a JSON map, eg {\"foo\":\"bar\",\"baz\":\"bin\"}.
jsonMap :: [(String, Json url ())] -> Json url ()
jsonMap = jsonMap' . fromList

-- | Same as 'jsonMap', but uses an 'Enumerator' for input.
jsonMap' :: Enumerator (String, Json url ()) (Json url) -> Json url () -- FIXME simplify type
jsonMap' (Enumerator enum) = do
    Json $ outputString "{"
    _ <- enum go False
    Json $ outputString "}"
  where
    go putComma (k, v) = do
        when putComma $ Json $ outputString ","
        jsonScalar $ Unencoded $ pack k
        Json $ outputString ":"
        () <- v
        return $ Right True

#if TEST

testSuite :: Test
testSuite = testGroup "Yesod.Json"
    [ testCase "simple output" caseSimpleOutput
    ]

caseSimpleOutput :: Assertion
caseSimpleOutput = do
    let j = do
        jsonMap
            [ ("foo" , jsonList
                [ jsonScalar $ Encoded $ pack "bar"
                , jsonScalar $ Encoded $ pack "baz"
                ])
            ]
    t <- hamletToText id $ unJson j
    "{\"foo\":[\"bar\",\"baz\"]}" @=? unpack t

#endif