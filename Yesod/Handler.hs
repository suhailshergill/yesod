{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE CPP #-}
---------------------------------------------------------
--
-- Module        : Yesod.Handler
-- Copyright     : Michael Snoyman
-- License       : BSD3
--
-- Maintainer    : Michael Snoyman <michael@snoyman.com>
-- Stability     : unstable
-- Portability   : portable
--
-- Define Handler stuff.
--
---------------------------------------------------------
module Yesod.Handler
    ( -- * Handler monad
      Handler
    , GHandler
      -- ** Read information from handler
    , getYesod
    , getYesodSub
    , getUrlRender
    , getRoute
    , getRouteToMaster
      -- * Special responses
      -- ** Redirecting
    , RedirectType (..)
    , redirect
    , redirectParams
    , redirectString
      -- ** Errors
    , notFound
    , badMethod
    , permissionDenied
    , invalidArgs
      -- ** Sending static files
    , sendFile
      -- * Setting headers
    , addCookie
    , deleteCookie
    , header
    , setLanguage
      -- * Session
    , setSession
    , clearSession
      -- ** Ultimate destination
    , setUltDest
    , setUltDestString
    , setUltDest'
    , redirectUltDest
      -- ** Messages
    , setMessage
    , getMessage
      -- * Internal Yesod
    , runHandler
    , YesodApp (..)
    ) where

import Prelude hiding (catch)
import Yesod.Request
import Yesod.Content
import Yesod.Internal
import Web.Routes.Quasi (Routes)
import Data.List (foldl', intercalate)

import Control.Exception hiding (Handler, catch)
import qualified Control.Exception as E
import Control.Applicative

import "transformers" Control.Monad.IO.Class
import qualified "MonadCatchIO-transformers" Control.Monad.CatchIO as C
import "MonadCatchIO-transformers" Control.Monad.CatchIO (catch)
import Control.Monad (liftM, ap)

import System.IO
import qualified Data.ByteString.Lazy as BL
import qualified Network.Wai as W
import Control.Monad.Attempt

import Data.Convertible.Text (cs)
import Text.Hamlet
import Numeric (showIntAtBase)
import Data.Char (ord, chr)

data HandlerData sub master = HandlerData
    { handlerRequest :: Request
    , handlerSub :: sub
    , handlerMaster :: master
    , handlerRoute :: Maybe (Routes sub)
    , handlerRender :: (Routes master -> String)
    , handlerToMaster :: Routes sub -> Routes master
    }

-- | A generic handler monad, which can have a different subsite and master
-- site. This monad is a combination of reader for basic arguments, a writer
-- for headers, and an error-type monad for handling special responses.
newtype GHandler sub master a = Handler {
    unHandler :: HandlerData sub master
              -> IO ([Header], [(String, Maybe String)], HandlerContents a)
}

-- | A 'GHandler' limited to the case where the master and sub sites are the
-- same. This is the usual case for application writing; only code written
-- specifically as a subsite need been concerned with the more general variety.
type Handler yesod = GHandler yesod yesod

-- | An extension of the basic WAI 'W.Application' datatype to provide extra
-- features needed by Yesod. Users should never need to use this directly, as
-- the 'GHandler' monad and template haskell code should hide it away.
newtype YesodApp = YesodApp
    { unYesodApp
    :: (ErrorResponse -> YesodApp)
    -> Request
    -> [ContentType]
    -> IO (W.Status, [Header], ContentType, Content, [(String, String)])
    }

data HandlerContents a =
      HCContent a
    | HCError ErrorResponse
    | HCSendFile ContentType FilePath
    | HCRedirect RedirectType String

instance Functor (GHandler sub master) where
    fmap = liftM
instance Applicative (GHandler sub master) where
    pure = return
    (<*>) = ap
instance Monad (GHandler sub master) where
    fail = failure . InternalError -- We want to catch all exceptions anyway
    return x = Handler $ \_ -> return ([], [], HCContent x)
    (Handler handler) >>= f = Handler $ \rr -> do
        (headers, session', c) <- handler rr
        (headers', session'', c') <-
            case c of
                HCContent a -> unHandler (f a) rr
                HCError e -> return ([], [], HCError e)
                HCSendFile ct fp -> return ([], [], HCSendFile ct fp)
                HCRedirect rt url -> return ([], [], HCRedirect rt url)
        return (headers ++ headers', session' ++ session'', c')
instance MonadIO (GHandler sub master) where
    liftIO i = Handler $ \_ -> i >>= \i' -> return ([], [], HCContent i')
instance C.MonadCatchIO (GHandler sub master) where
    catch (Handler m) f =
        Handler $ \d -> E.catch (m d) (\e -> unHandler (f e) d)
    block (Handler m) =
        Handler $ E.block . m
    unblock (Handler m) =
        Handler $ E.unblock . m
instance Failure ErrorResponse (GHandler sub master) where
    failure e = Handler $ \_ -> return ([], [], HCError e)
instance RequestReader (GHandler sub master) where
    getRequest = handlerRequest <$> getData

getData :: GHandler sub master (HandlerData sub master)
getData = Handler $ \r -> return ([], [], HCContent r)

-- | Get the sub application argument.
getYesodSub :: GHandler sub master sub
getYesodSub = handlerSub <$> getData

-- | Get the master site appliation argument.
getYesod :: GHandler sub master master
getYesod = handlerMaster <$> getData

-- | Get the URL rendering function.
getUrlRender :: GHandler sub master (Routes master -> String)
getUrlRender = handlerRender <$> getData

-- | Get the route requested by the user. If this is a 404 response- where the
-- user requested an invalid route- this function will return 'Nothing'.
getRoute :: GHandler sub master (Maybe (Routes sub))
getRoute = handlerRoute <$> getData

-- | Get the function to promote a route for a subsite to a route for the
-- master site.
getRouteToMaster :: GHandler sub master (Routes sub -> Routes master)
getRouteToMaster = handlerToMaster <$> getData

modifySession :: [(String, String)] -> (String, Maybe String)
              -> [(String, String)]
modifySession orig (k, v) =
    case v of
        Nothing -> dropKeys k orig
        Just v' -> (k, v') : dropKeys k orig

dropKeys :: String -> [(String, x)] -> [(String, x)]
dropKeys k = filter $ \(x, _) -> x /= k

-- | Function used internally by Yesod in the process of converting a
-- 'GHandler' into an 'W.Application'. Should not be needed by users.
runHandler :: HasReps c
           => GHandler sub master c
           -> (Routes master -> String)
           -> Maybe (Routes sub)
           -> (Routes sub -> Routes master)
           -> master
           -> (master -> sub)
           -> YesodApp
runHandler handler mrender sroute tomr ma tosa = YesodApp $ \eh rr cts -> do
    let toErrorHandler =
            InternalError
          . (show :: Control.Exception.SomeException -> String)
    (headers, session', contents) <- E.catch
        (unHandler handler HandlerData
            { handlerRequest = rr
            , handlerSub = tosa ma
            , handlerMaster = ma
            , handlerRoute = sroute
            , handlerRender = mrender
            , handlerToMaster = tomr
            })
        (\e -> return ([], [], HCError $ toErrorHandler e))
    let finalSession = foldl' modifySession (reqSession rr) session'
    let handleError e = do
            (_, hs, ct, c, sess) <- unYesodApp (eh e) safeEh rr cts
            let hs' = headers ++ hs
            return (getStatus e, hs', ct, c, sess)
    let sendFile' ct fp = do
            c <- BL.readFile fp
            return (W.Status200, headers, ct, cs c, finalSession)
    case contents of
        HCContent a -> do
            (ct, c) <- chooseRep a cts
            return (W.Status200, headers, ct, c, finalSession)
        HCError e -> handleError e
        HCRedirect rt loc -> do
            let hs = Header "Location" loc : headers
            return (getRedirectStatus rt, hs, typePlain, cs "", finalSession)
        HCSendFile ct fp -> E.catch
            (sendFile' ct fp)
            (handleError . toErrorHandler)

safeEh :: ErrorResponse -> YesodApp
safeEh er = YesodApp $ \_ _ _ -> do
    liftIO $ hPutStrLn stderr $ "Error handler errored out: " ++ show er
    return (W.Status500, [], typePlain, cs "Internal Server Error", [])

-- | Redirect to the given route.
redirect :: RedirectType -> Routes master -> GHandler sub master a
redirect rt url = do
    r <- getUrlRender
    redirectString rt $ r url

-- | Redirects to the given route with the associated query-string parameters.
redirectParams :: RedirectType -> Routes master -> [(String, String)]
               -> GHandler sub master a
redirectParams rt url params = do
    r <- getUrlRender
    redirectString rt $ r url ++ '?' : encodeUrlPairs params
  where
    encodeUrlPairs = intercalate "&" . map encodeUrlPair
    encodeUrlPair (x, []) = escape x
    encodeUrlPair (x, y) = escape x ++ '=' : escape y
    escape = concatMap escape'
    escape' c
        | 'A' < c && c < 'Z' = [c]
        | 'a' < c && c < 'a' = [c]
        | '0' < c && c < '9' = [c]
        | c `elem` ".-~_" = [c]
        | c == ' ' = "+"
        | otherwise = '%' : myShowHex (ord c) ""
    myShowHex :: Int -> ShowS
    myShowHex n r =  case showIntAtBase 16 (toChrHex) n r of
        []  -> "00"
        [c] -> ['0',c]
        s  -> s
    toChrHex d
        | d < 10    = chr (ord '0' + fromIntegral d)
        | otherwise = chr (ord 'A' + fromIntegral (d - 10))

-- | Redirect to the given URL.
redirectString :: RedirectType -> String -> GHandler sub master a
redirectString rt url = Handler $ \_ -> return ([], [], HCRedirect rt url)

ultDestKey :: String
ultDestKey = "_ULT"

-- | Sets the ultimate destination variable to the given route.
--
-- An ultimate destination is stored in the user session and can be loaded
-- later by 'redirectUltDest'.
setUltDest :: Routes master -> GHandler sub master ()
setUltDest dest = do
    render <- getUrlRender
    setUltDestString $ render dest

-- | Same as 'setUltDest', but use the given string.
setUltDestString :: String -> GHandler sub master ()
setUltDestString = setSession ultDestKey

-- | Same as 'setUltDest', but uses the current page.
--
-- If this is a 404 handler, there is no current page, and then this call does
-- nothing.
setUltDest' :: GHandler sub master ()
setUltDest' = do
    route <- getRoute
    tm <- getRouteToMaster
    maybe (return ()) setUltDest $ tm <$> route

-- | Redirect to the ultimate destination in the user's session. Clear the
-- value from the session.
--
-- The ultimate destination is set with 'setUltDest'.
redirectUltDest :: RedirectType
                -> Routes master -- ^ default destination if nothing in session
                -> GHandler sub master ()
redirectUltDest rt def = do
    mdest <- lookupSession ultDestKey
    clearSession ultDestKey
    maybe (redirect rt def) (redirectString rt) mdest

msgKey :: String
msgKey = "_MSG"

-- | Sets a message in the user's session.
--
-- See 'getMessage'.
setMessage :: Html -> GHandler sub master ()
setMessage = setSession msgKey . cs . renderHtml

-- | Gets the message in the user's session, if available, and then clears the
-- variable.
--
-- See 'setMessage'.
getMessage :: GHandler sub master (Maybe Html)
getMessage = do
    clearSession msgKey
    fmap (fmap $ preEscapedString . cs) $ lookupSession msgKey

-- | Bypass remaining handler code and output the given file.
--
-- For some backends, this is more efficient than reading in the file to
-- memory, since they can optimize file sending via a system call to sendfile.
sendFile :: ContentType -> FilePath -> GHandler sub master a
sendFile ct fp = Handler $ \_ -> return ([], [], HCSendFile ct fp)

-- | Return a 404 not found page. Also denotes no handler available.
notFound :: Failure ErrorResponse m => m a
notFound = failure NotFound

-- | Return a 405 method not supported page.
badMethod :: (RequestReader m, Failure ErrorResponse m) => m a
badMethod = do
    w <- waiRequest
    failure $ BadMethod $ cs $ W.methodToBS $ W.requestMethod w

-- | Return a 403 permission denied page.
permissionDenied :: Failure ErrorResponse m => m a
permissionDenied = failure $ PermissionDenied "Permission denied"

-- | Return a 400 invalid arguments page.
invalidArgs :: Failure ErrorResponse m => [(ParamName, String)] -> m a
invalidArgs = failure . InvalidArgs

------- Headers
-- | Set the cookie on the client.
addCookie :: Int -- ^ minutes to timeout
          -> String -- ^ key
          -> String -- ^ value
          -> GHandler sub master ()
addCookie a b = addHeader . AddCookie a b

-- | Unset the cookie on the client.
deleteCookie :: String -> GHandler sub master ()
deleteCookie = addHeader . DeleteCookie

-- | Set the language header. Will show up in 'languages'.
setLanguage :: String -> GHandler sub master ()
setLanguage = addCookie 60 langKey

-- | Set an arbitrary header on the client.
header :: String -> String -> GHandler sub master ()
header a = addHeader . Header a

-- | Set a variable in the user's session.
--
-- The session is handled by the clientsession package: it sets an encrypted
-- and hashed cookie on the client. This ensures that all data is secure and
-- not tampered with.
setSession :: String -- ^ key
           -> String -- ^ value
           -> GHandler sub master ()
setSession k v = Handler $ \_ -> return ([], [(k, Just v)], HCContent ())

-- | Unsets a session variable. See 'setSession'.
clearSession :: String -> GHandler sub master ()
clearSession k = Handler $ \_ -> return ([], [(k, Nothing)], HCContent ())

addHeader :: Header -> GHandler sub master ()
addHeader h = Handler $ \_ -> return ([h], [], HCContent ())

getStatus :: ErrorResponse -> W.Status
getStatus NotFound = W.Status404
getStatus (InternalError _) = W.Status500
getStatus (InvalidArgs _) = W.Status400
getStatus (PermissionDenied _) = W.Status403
getStatus (BadMethod _) = W.Status405

getRedirectStatus :: RedirectType -> W.Status
getRedirectStatus RedirectPermanent = W.Status301
getRedirectStatus RedirectTemporary = W.Status302
getRedirectStatus RedirectSeeOther = W.Status303

-- | Different types of redirects.
data RedirectType = RedirectPermanent
                  | RedirectTemporary
                  | RedirectSeeOther
    deriving (Show, Eq)
