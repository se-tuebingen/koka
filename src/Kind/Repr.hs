------------------------------------------------------------------------------
-- Copyright 2012-2023, Microsoft Research, Daan Leijen.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the LICENSE file at the root of this distribution.
-----------------------------------------------------------------------------
{-
    
-}
-----------------------------------------------------------------------------
module Kind.Repr( orderConFields, createDataDef ) where

import Control.Monad( when )
import Lib.PPrint
import Common.Name
import Common.NamePrim
import Common.Syntax
import Common.Failure
import Type.Type

---------------------------------------------------------
-- Create a datadef and elaborate conInfo's with a ValueRepr
-- and correctly ordered fields depending on alignment
-- constraints and platform sizes.
---------------------------------------------------------

-- value types
createDataDef :: Monad m => (Doc-> m ()) -> (Doc-> m ()) -> (Name -> m (Maybe DataInfo))
                               -> Platform -> Name -> Bool -> Bool -> DataKind 
                                 -> Int -> DataDef -> [ConInfo] -> m (DataDef,[ConInfo])
createDataDef emitError emitWarning lookupDataInfo 
               platform name resultHasKindStar isRec sort 
                extraFields defaultDef conInfos0
  = do --calculate the value repr of each constructor
       conInfos <- mapM createConInfoRepr conInfos0
       -- datadef 
       ddef  <- case defaultDef of
                  DataDefNormal
                    -> return (if (isRec) then DataDefRec else DataDefNormal)
                  DataDefValue{} | isRec
                    -> do emitError $ text "cannot be declared as a value type since it is recursive."
                          return defaultDef
                  DataDefAuto | isRec
                    -> return DataDefRec
                  -- DataDefAuto | isAsMaybe
                  --  -> return DataDefNormal
                  DataDefOpen
                    -> return DataDefOpen
                  DataDefRec
                    -> return DataDefRec
                  _ -- Value or auto, and not recursive
                    -> -- determine the raw fields and total size
                       do dd <- createMaxDataDef conInfos
                          case (defaultDef,dd) of  -- note: m = raw, n = scan
                            (DataDefValue _, DataDefValue vr)
                              -> if resultHasKindStar
                                  then return (DataDefValue vr)
                                  else do emitError $ text "is declared as a value type but does not have a value kind ('V')."  -- should never happen?
                                          return DataDefNormal
                            (DataDefValue _, DataDefNormal)
                              -> do emitError $ text "cannot be used as a value type."  -- should never happen?
                                    return DataDefNormal
                            (DataDefAuto, DataDefValue vr)
                              -> if (valueReprSize platform vr <= 3*(sizePtr platform)         -- not too large in bytes
                                      && maximum (map (length . conInfoParams) conInfos) <= 3  -- and at most 3 members
                                      && resultHasKindStar
                                      && (sort /= Retractive))
                                  then -- trace ("default to value: " ++ show name ++ ": " ++ show vr) $
                                       return (DataDefValue vr)
                                  else -- trace ("default to reference: " ++ show name ++ ": " ++ show vr ++ ", " ++ show (valueReprSize platform vr)) $
                                       return (DataDefNormal)
                            _ -> return DataDefNormal
       return (ddef,conInfos)
  where
    isVal :: Bool
    isVal = dataDefIsValue defaultDef

    -- createConInfoRepr :: ConInfo -> m ConInfo
    createConInfoRepr conInfo
      = do (orderedFields,vrepr) <- orderConFields emitError (text "constructor" <+> pretty (conInfoName conInfo)) 
                                                   lookupDataInfo platform extraFields (conInfoParams conInfo)
           return (conInfo{ conInfoOrderedParams = orderedFields, conInfoValueRepr = vrepr } )

    -- createMaxDataDef :: [ConInfo] -> m DataDef
    createMaxDataDef conInfos
      =  do let vreprs = map conInfoValueRepr conInfos
            ddef <- maxDataDefs vreprs
            case ddef of
              DataDefValue (ValueRepr 0 0 0) -- enumeration
                -> let n = length conInfos
                  in if (n < 256)         then return $ DataDefValue (valueReprRaw 1) -- uint8_t
                      else if (n < 65536) then return $ DataDefValue (valueReprRaw 2) -- uint16_t
                                          else return $ DataDefValue (valueReprRaw 4) -- uint32_t
              _ -> return ddef


    -- note: (m = raw, n = scan)
    -- maxDataDefs :: Monad m => [ValueRepr] -> m DataDef
    maxDataDefs [] 
      = if not isVal 
          then return DataDefNormal -- reference type, no constructors
          else do let size  = if (name == nameTpChar || name == nameTpInt32 || name == nameTpFloat32)
                               then 4
                              else if (name == nameTpFloat || name == nameTpInt64)
                               then 8
                              else if (name == nameTpInt8)
                               then 1
                              else if (name == nameTpInt16 || name == nameTpFloat16)
                               then 2
                              else if (name == nameTpAny || name == nameTpCField || name == nameTpIntPtrT)
                               then (sizePtr platform)
                              else if (name==nameTpSSizeT)
                               then (sizeSize platform)
                              else 0
                  m <- if (size <= 0)
                        then do emitWarning $ text "is declared as a primitive value type but has no known compilation size, assuming size" <+> pretty (sizePtr platform)
                                return (sizePtr platform)
                        else return size
                  return (DataDefValue (valueReprNew m 0 m))
    maxDataDefs [vr] -- singleton value
      = return (DataDefValue vr)
    maxDataDefs (vr:vrs)
      = do dd <- maxDataDefs vrs
           case (vr,dd) of
              (ValueRepr 0 0 _,    DataDefValue v)                  -> return (DataDefValue v)
              (v,                  DataDefValue (ValueRepr 0 0 _))  -> return (DataDefValue v)
              (ValueRepr m1 0 a1,  DataDefValue (ValueRepr m2 0 a2)) 
                -> return (DataDefValue (valueReprNew (max m1 m2) 0 (max a1 a2)))
              (ValueRepr 0 n1 a1,  DataDefValue (ValueRepr 0 n2 a2)) 
                -> return (DataDefValue (valueReprNew 0 (max n1 n2) (max a1 a2)))
              (ValueRepr m1 n1 a1, DataDefValue (ValueRepr m2 n2 a2))
                -- equal scan fields
                | n1 == n2  -> return (DataDefValue (valueReprNew (max m1 m2) n1 (max a1 a2)))
                -- non-equal scan fields
                | otherwise ->
                  do if (isVal)
                      then emitError (text "is declared as a value type but has" <+> text "multiple constructors with a different number of regular types overlapping with value types." <->
                                        text "hint: value types with multiple constructors must all use the same number of regular types (use 'box' to use a value type as a regular type).")
                      else emitWarning (text "cannot be defaulted to a value type as it has" <+> text "multiple constructors with a different number of regular types overlapping with value types.")
                     -- trace ("warning: cannot default to a value type due to mixed raw/regular fields: " ++ show nameDoc) $
                     return DataDefNormal -- (DataDefValue (max m1 m2) (max n1 n2))
              _ -> return DataDefNormal


---------------------------------------------------------
-- Determine the size of a constructor
---------------------------------------------------------

-- order constructor fields of constructors with raw field so the regular fields come first to be scanned.
-- return the ordered fields, and a ValueRepr (raw size part, the scan count (including tags), align, and full size)
-- The size is used for reuse and should include all needed fields including the tag field for "open" datatypes 
orderConFields :: Monad m => (Doc -> m ()) -> Doc -> (Name -> m (Maybe DataInfo)) -> Platform
                               -> Int -> [(Name,Type)] -> m ([(Name,Type)],ValueRepr)
orderConFields emitError nameDoc getDataInfo platform extraPreScan fields
  = do visit ([], [], [], extraPreScan, 0) fields
  where
    -- visit :: ([((Name,Type),Int,Int,Int)],[((Name,Type),Int,Int,Int)],[(Name,Type)],Int,Int) -> [(Name,Type)] -> m ([(Name,Type)],ValueRepr)
    visit (rraw, rmixed, rscan, scanCount0, alignment0) []  
      = do when (length rmixed > 1) $
             do emitError (nameDoc <+> text "has multiple value type fields that each contain both raw types and regular types." <->
                             text ("hint: use 'box' on either field to make it a non-value type."))
           let  -- scancount and size before any mixed and raw fields
                preSize    = (sizeHeader platform) + (scanCount0 * sizeField platform)

                -- if there is a mixed value member (with scan fields) we may need to add padding scan fields (!)
                -- (or otherwise the C compiler may insert uninitialized padding)
                (padding,mixedScan)   
                          = case rmixed of
                              ((_,_,scan,ralign):_) 
                                 -> let padSize    = preSize `mod` ralign
                                        padCount   = padSize `div` sizeField platform
                                    in assertion ("Kind.Infer.orderConFields: illegal alignment: " ++ show ralign) (padSize `mod` sizeField platform == 0) $
                                       ([((newPaddingName (scanCount0 + i),typeAny),sizeField platform,1,sizeField platform) | i <- [1..padCount]]
                                       ,scan + padCount)
                              [] -> ([],0)

                -- calculate the rest now
                scanCount = scanCount0 + mixedScan  
                alignment = if scanCount > 0 then max alignment0 (sizeField platform) else alignment0
                rest      = padding ++ rmixed ++ reverse rraw
                restSizes = [size  | (_field,size,_scan,_align) <- rest]
                restFields= [field | (field,_size,_scan,_align) <- rest]
                size      = alignedSum preSize restSizes                            
                rawSize   = size - (sizeHeader platform) - (scanCount * sizeField platform)
                vrepr     = valueReprNew rawSize scanCount alignment
           -- (if null padding then id else trace ("constructor: " ++ show cname ++ ": " ++ show vrepr) $
           return (reverse rscan ++ restFields, vrepr)

    visit (rraw,rmixed,rscan,scanCount,alignment0) (field@(name,tp) : fs)
      = do mDataDef <- getDataDef getDataInfo tp
           case mDataDef of
             Just (DataDefValue (ValueRepr raw scan align))
               -> -- let extra = if (hasTagField dataRepr) then 1 else 0 in -- adjust scan count for added "tag_t" members in structs with multiple constructors
                  let alignment = max align alignment0 in
                  if (raw > 0 && scan > 0)
                   then -- mixed raw/scan: put it at the head of the raw fields (there should be only one of these as checked in Kind/Infer)
                        -- but we count them to be sure (and for function data)
                        visit (rraw, (field,raw,scan,align):rmixed, rscan, scanCount, alignment) fs
                   else if (raw > 0)
                         then visit (insertRaw field raw scan align rraw, rmixed, rscan, scanCount, alignment) fs
                         else visit (rraw, rmixed, field:rscan, scanCount + scan, alignment) fs
             _ -> visit (rraw, rmixed, field:rscan, scanCount + 1, alignment0) fs

    -- insert raw fields in (reversed) order of alignment so they align to the smallest total size in a datatype
    insertRaw :: (Name,Type) -> Int -> Int -> Int -> [((Name,Type),Int,Int,Int)] -> [((Name,Type),Int,Int,Int)]
    insertRaw field raw scan align ((f,r,s,a):rs)
      | align <= a  = (field,raw,scan,align):(f,r,s,a):rs
      | otherwise   = (f,r,s,a):insertRaw field raw scan align rs
    insertRaw field raw scan align []
      = [(field,raw,scan,align)]
    
    

-- | Return the DataDef for a type.
-- This may be 'Nothing' for abstract types.
getDataDef :: Monad m => (Name -> m (Maybe DataInfo)) -> Type -> m (Maybe DataDef)
getDataDef lookupDI tp
   = case extractDataDefType tp of
       Nothing -> return $ Just DataDefNormal
       Just name | name == nameTpBox -> return $ Just DataDefNormal
       Just name -> do mdi <- lookupDI name 
                       case mdi of
                         Nothing -> return Nothing
                         Just di -> return $ Just (dataInfoDef di)
    where 
      extractDataDefType :: Type -> Maybe Name
      extractDataDefType tp
        = case expandSyn tp of
            TApp t _      -> extractDataDefType t
            TForall _ _ t -> extractDataDefType t
            TCon tc       -> Just (typeConName tc)
            _             -> Nothing

