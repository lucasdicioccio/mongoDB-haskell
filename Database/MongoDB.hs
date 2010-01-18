{-

Copyright (C) 2010 Scott R Parish <srp@srparish.net>

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-}

module Database.MongoDB
    (
     -- * Connection
     Connection,
     connect, connectOnPort, conClose, disconnect,
     -- * Basic database operations
     Collection, FieldSelector, NumToSkip, NumToReturn, Selector,
     QueryOpt(..),
     UpdateFlag(..),
     delete, insert, insertMany, query, remove, update,
     -- * Convience database operations
     find, quickFind, quickFind',
     -- * Cursor operations
     Cursor,
     allDocs, allDocs', finish, nextDoc,
    )
where
import Control.Exception
import Control.Monad
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits
import Data.ByteString.Char8 hiding (find)
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.UTF8 as L8
import Data.Int
import Data.IORef
import qualified Data.List as List
import Data.Typeable
import Database.MongoDB.BSON
import Database.MongoDB.Util
import qualified Network
import Network.Socket hiding (connect, send, sendTo, recv, recvFrom)
import Prelude hiding (getContents)
import System.IO
import System.IO.Unsafe
import System.Random

-- | A handle to a database connection
data Connection = Connection { cHandle :: Handle, cRand :: IORef [Int] }

-- | Estabilish a connection to a MongoDB server
connect :: HostName -> IO Connection
connect = flip connectOnPort $ Network.PortNumber 27017

-- | Estabilish a connection to a MongoDB server on a non-standard port
connectOnPort :: HostName -> Network.PortID -> IO Connection
connectOnPort host port = do
  h <- Network.connectTo host port
  hSetBuffering h NoBuffering
  r <- newStdGen
  let ns = randomRs (fromIntegral (minBound :: Int32),
                     fromIntegral (maxBound :: Int32)) r
  nsRef <- newIORef ns
  return $ Connection { cHandle = h, cRand = nsRef }

-- | Close database connection
conClose :: Connection -> IO ()
conClose = hClose . cHandle

-- | Alias for 'conClose'
disconnect :: Connection -> IO ()
disconnect = conClose

-- | An Itertaor over the results of a query. Use 'nextDoc' to get each
-- successive result document, or 'allDocs' or 'allDocs'' to get lazy or
-- strict lists of results.
data Cursor = Cursor {
      curCon :: Connection,
      curID :: IORef Int64,
      curNumToRet :: Int32,
      curCol :: Collection,
      curDocBytes :: IORef L.ByteString,
      curClosed :: IORef Bool
    }

data Opcode
    = OP_REPLY          -- 1     Reply to a client request. responseTo is set
    | OP_MSG            -- 1000	 generic msg command followed by a string
    | OP_UPDATE         -- 2001  update document
    | OP_INSERT	        -- 2002	 insert new document
    | OP_GET_BY_OID	-- 2003	 is this used?
    | OP_QUERY	        -- 2004	 query a collection
    | OP_GET_MORE	-- 2005	 Get more data from a query. See Cursors
    | OP_DELETE	        -- 2006	 Delete documents
    | OP_KILL_CURSORS	-- 2007	 Tell database client is done with a cursor
    deriving (Show, Eq)

data MongoDBInternalError = MongoDBInternalError String
                            deriving (Eq, Show, Read)

mongoDBInternalError :: TyCon
mongoDBInternalError = mkTyCon "Database.MongoDB.MongoDBInternalError"

instance Typeable MongoDBInternalError where
    typeOf _ = mkTyConApp mongoDBInternalError []

instance Exception MongoDBInternalError

fromOpcode :: Opcode -> Int32
fromOpcode OP_REPLY        =    1
fromOpcode OP_MSG          = 1000
fromOpcode OP_UPDATE       = 2001
fromOpcode OP_INSERT       = 2002
fromOpcode OP_GET_BY_OID   = 2003
fromOpcode OP_QUERY        = 2004
fromOpcode OP_GET_MORE     = 2005
fromOpcode OP_DELETE       = 2006
fromOpcode OP_KILL_CURSORS = 2007

toOpcode :: Int32 -> Opcode
toOpcode    1 = OP_REPLY
toOpcode 1000 = OP_MSG
toOpcode 2001 = OP_UPDATE
toOpcode 2002 = OP_INSERT
toOpcode 2003 = OP_GET_BY_OID
toOpcode 2004 = OP_QUERY
toOpcode 2005 = OP_GET_MORE
toOpcode 2006 = OP_DELETE
toOpcode 2007 = OP_KILL_CURSORS
toOpcode n = throw $ MongoDBInternalError $ "Got unexpected Opcode: " ++ show n

-- | The full collection name. The full collection name is the
-- concatenation of the database name with the collection name, using
-- a @.@ for the concatenation. For example, for the database @foo@
-- and the collection @bar@, the full collection name is @foo.bar@.
type Collection = String

-- | A 'BsonDoc' representing restrictions for a query much like the
-- /where/ part of an SQL query.
type Selector = BsonDoc
-- | A list of field names that limits the fields in the returned
-- documents. The list can contains zero or more elements, each of
-- which is the name of a field that should be returned. An empty list
-- means that no limiting is done and all fields are returned.
type FieldSelector = [L8.ByteString]
type RequestID = Int32
-- | Sets the number of documents to omit - starting from the first
-- document in the resulting dataset - when returning the result of
-- the query.
type NumToSkip = Int32
-- | This controls how many documents are returned at a time. The
-- cursor works by requesting /NumToReturn/ documents, which are then
-- immediately all transfered over the network; these are held locally
-- until the those /NumToReturn/ are all consumed and then the network
-- will be hit again for the next /NumToReturn/ documents.
--
-- If the value @0@ is given, the database will choose the number of
-- documents to return.
--
-- Otherwise choosing a good value is very dependant on the document size
-- and the way the cursor is being used.
type NumToReturn = Int32

-- | Options that control the behavior of a 'query' operation.
data QueryOpt = QO_TailableCursor
               | QO_SlaveOK
               | QO_OpLogReplay
               | QO_NoCursorTimeout
               deriving (Show)

fromQueryOpts :: [QueryOpt] -> Int32
fromQueryOpts opts = List.foldl (.|.) 0 $ fmap toVal opts
    where toVal QO_TailableCursor = 2
          toVal QO_SlaveOK = 4
          toVal QO_OpLogReplay = 8
          toVal QO_NoCursorTimeout = 16

-- | Options that effect the behavior of a 'update' operation.
data UpdateFlag = UF_Upsert
                | UF_Multiupdate
                deriving (Show, Enum)

fromUpdateFlags :: [UpdateFlag] -> Int32
fromUpdateFlags flags = List.foldl (.|.) 0 $
                        flip fmap flags $ (1 `shiftL`) . fromEnum

-- | Delete documents matching /Selector/ from the given /Collection/.
delete :: Connection -> Collection -> Selector -> IO RequestID
delete c col sel = do
  let body = runPut $ do
                     putI32 0
                     putCol col
                     putI32 0
                     put sel
  (reqID, msg) <- packMsg c OP_DELETE body
  L.hPut (cHandle c) msg
  return reqID

-- | An alias for 'delete'.
remove :: Connection -> Collection -> Selector -> IO RequestID
remove = delete

-- | Insert a single document into /Collection/.
insert :: Connection -> Collection -> BsonDoc -> IO RequestID
insert c col doc = do
  let body = runPut $ do
                     putI32 0
                     putCol col
                     put doc
  (reqID, msg) <- packMsg c OP_INSERT body
  L.hPut (cHandle c) msg
  return reqID

-- | Insert a list of documents into /Collection/.
insertMany :: Connection -> Collection -> [BsonDoc] -> IO RequestID
insertMany c col docs = do
  let body = runPut $ do
               putI32 0
               putCol col
               forM_ docs put
  (reqID, msg) <- packMsg c OP_INSERT body
  L.hPut (cHandle c) msg
  return reqID

-- | Open a cursor to find documents. If you need full functionality,
-- see 'query'
find :: Connection -> Collection -> Selector -> IO Cursor
find c col sel = query c col [] 0 0 sel []

-- | Perform a query and return the result as a lazy list. Be sure to
-- understand the comments about using the lazy list given for
-- 'allDocs'.
quickFind :: Connection -> Collection -> Selector -> IO [BsonDoc]
quickFind c col sel = find c col sel >>= allDocs

-- | Perform a query and return the result as a strict list.
quickFind' :: Connection -> Collection -> Selector -> IO [BsonDoc]
quickFind' c col sel = find c col sel >>= allDocs'

-- | Open a cursor to find documents in /Collection/ that match
-- /Selector/. See the documentation for each argument's type for
-- information about how it effects the query.
query :: Connection -> Collection -> [QueryOpt] -> NumToSkip -> NumToReturn ->
         Selector -> FieldSelector -> IO Cursor
query c col opts nskip ret sel fsel = do
  let h = cHandle c

  let body = runPut $ do
               putI32 $ fromQueryOpts opts
               putCol col
               putI32 nskip
               putI32 ret
               put sel
               case fsel of
                    [] -> putNothing
                    _ -> put $ toBsonDoc $ List.zip fsel $ repeat $ BsonInt32 1
  (reqID, msg) <- packMsg c OP_QUERY body
  L.hPut h msg

  hdr <- getHeader h
  assert (OP_REPLY == hOp hdr) $ return ()
  assert (hRespTo hdr == reqID) $ return ()
  reply <- getReply h
  assert (rRespFlags reply == 0) $ return ()
  docBytes <- (L.hGet h $ fromIntegral $ hMsgLen hdr - 16 - 20) >>= newIORef
  closed <- newIORef False
  cid <- newIORef $ rCursorID reply
  return $ Cursor {
               curCon = c,
               curID = cid,
               curNumToRet = ret,
               curCol = col,
               curDocBytes = docBytes,
               curClosed = closed
             }

-- | Update documents with /BsonDoc/ in /Collection/ that match /Selector/.
update :: Connection -> Collection ->
          [UpdateFlag] -> Selector -> BsonDoc -> IO RequestID
update c col flags sel obj = do
  let body = runPut $ do
               putI32 0
               putCol col
               putI32 $ fromUpdateFlags flags
               put sel
               put obj
  (reqID, msg) <- packMsg c OP_UPDATE body
  L.hPut (cHandle c) msg
  return reqID

data Hdr = Hdr {
      hMsgLen :: Int32,
      -- hReqID :: Int32,
      hRespTo :: Int32,
      hOp :: Opcode
    } deriving (Show)

data Reply = Reply {
      rRespFlags :: Int32,
      rCursorID :: Int64
      -- rStartFrom :: Int32,
      -- rNumReturned :: Int32
    } deriving (Show)

getHeader :: Handle -> IO Hdr
getHeader h = do
  hdrBytes <- L.hGet h 16
  return $ flip runGet hdrBytes $ do
                msgLen <- getI32
                skip 4 -- reqID <- getI32
                respTo <- getI32
                op <- getI32
                return $ Hdr msgLen respTo $ toOpcode op

getReply :: Handle -> IO Reply
getReply h = do
  replyBytes <- L.hGet h 20
  return $ flip runGet replyBytes $ do
               respFlags <- getI32
               cursorID <- getI64
               skip 4 -- startFrom <- getI32
               skip 4 -- numReturned <- getI32
               return $ (Reply respFlags cursorID)


-- | Return one document or Nothing if there are no more.
-- Automatically closes the curosr when last document is read
nextDoc :: Cursor -> IO (Maybe BsonDoc)
nextDoc cur = do
  closed <- readIORef $ curClosed cur
  case closed of
    True -> return Nothing
    False -> do
      docBytes <- readIORef $ curDocBytes cur
      cid <- readIORef $ curID cur
      case L.length docBytes of
        0 -> if cid == 0
             then writeIORef (curClosed cur) True >> return Nothing
             else getMore cur
        _ -> do
           let (doc, docBytes') = getFirstDoc docBytes
           writeIORef (curDocBytes cur) docBytes'
           return $ Just doc

-- | Return a lazy list of all (of the rest) of the documents in the
-- cursor. This works much like hGetContents--it will lazily read the
-- cursor data out of the database as the list is used. The cursor is
-- automatically closed when the list has been fully read.
--
-- If you manually finish the cursor before consuming off this list
-- you won't get all the original documents in the cursor.
--
-- If you don't consume to the end of the list, you must manually
-- close the cursor or you will leak the cursor, which may also leak
-- on the database side.
allDocs :: Cursor -> IO [BsonDoc]
allDocs cur = unsafeInterleaveIO $ do
                doc <- nextDoc cur
                case doc of
                  Nothing -> return []
                  Just d -> allDocs cur >>= return . (d :)

-- | Returns a strict list of all (of the rest) of the documents in
-- the cursor. This means that all of the documents will immediately
-- be read out of the database and loaded into memory.
allDocs' :: Cursor -> IO [BsonDoc]
allDocs' cur = do
  doc <- nextDoc cur
  case doc of
    Nothing -> return []
    Just d -> allDocs' cur >>= return . (d :)

getFirstDoc :: L.ByteString -> (BsonDoc, L.ByteString)
getFirstDoc docBytes = flip runGet docBytes $ do
                         doc <- get
                         docBytes' <- getRemainingLazyByteString
                         return (doc, docBytes')

getMore :: Cursor -> IO (Maybe BsonDoc)
getMore cur = do
  let h = cHandle $ curCon cur

  cid <- readIORef $ curID cur
  let body = runPut $ do
                putI32 0
                putCol $ curCol cur
                putI32 $ curNumToRet cur
                putI64 cid
  (reqID, msg) <- packMsg (curCon cur) OP_GET_MORE body
  L.hPut h msg

  hdr <- getHeader h
  assert (OP_REPLY == hOp hdr) $ return ()
  assert (hRespTo hdr == reqID) $ return ()
  reply <- getReply h
  assert (rRespFlags reply == 0) $ return ()
  case rCursorID reply of
       0 -> writeIORef (curID cur) 0
       ncid -> assert (ncid == cid) $ return ()
  docBytes <- (L.hGet h $ fromIntegral $ hMsgLen hdr - 16 - 20)
  case L.length docBytes of
    0 -> writeIORef (curClosed cur) True >> return Nothing
    _ -> do
      let (doc, docBytes') = getFirstDoc docBytes
      writeIORef (curDocBytes cur) docBytes'
      return $ Just doc

-- | Manually close a cursor -- usually not needed if you use
-- 'allDocs', 'allDocs'', or 'nextDoc'.
finish :: Cursor -> IO ()
finish cur = do
  let h = cHandle $ curCon cur
  cid <- readIORef $ curID cur
  let body = runPut $ do
                 putI32 0
                 putI32 1
                 putI64 cid
  (_reqID, msg) <- packMsg (curCon cur) OP_KILL_CURSORS body
  L.hPut h msg
  writeIORef (curClosed cur) True
  return ()

putCol :: Collection -> Put
putCol col = putByteString (pack col) >> putNull

packMsg :: Connection -> Opcode -> L.ByteString -> IO (RequestID, L.ByteString)
packMsg c op body = do
  reqID <- randNum c
  let msg = runPut $ do
                      putI32 $ fromIntegral $ L.length body + 16
                      putI32 reqID
                      putI32 0
                      putI32 $ fromOpcode op
                      putLazyByteString body
  return (reqID, msg)

randNum :: Connection -> IO Int32
randNum Connection { cRand = nsRef } = atomicModifyIORef nsRef $ \ns ->
                                       (List.tail ns,
                                        fromIntegral $ List.head ns)
