import os
import logging
import strutils
import sequtils
import options
import macros
import sugar

import ndb/sqlite
export sqlite

import private/sqlite/[dbtypes, rowutils]
import private/dot
import model
import pragmas

export dbtypes


type
  RollbackError* = object of CatchableError
    ##[ Raised when transaction is manually rollbacked.

    Do not raise manually, use `rollback <#rollback>`_ proc.
    ]##


const dbHostEnv* = "DB_HOST"


# Sugar to get DB config from environment variables

proc getDb*(): DbConn =
  ## Create a ``DbConn`` from ``DB_HOST`` environment variable.

  open(getEnv(dbHostEnv), "", "", "")

template withDb*(body: untyped): untyped =
  ##[ Wrapper for DB operations.

  Creates a ``DbConn`` with `getDb <#getDb>`_ as ``db`` variable,
  runs your code in a ``try`` block, and closes ``db`` afterward.
  ]##

  block:
    let db {.inject.} = getDb()

    try:
      body

    finally:
      close db


using dbConn: DbConn


# DB manipulation

proc dropDb* =
  ## Remove the DB file defined in environment variable.

  removeFile(getEnv(dbHostEnv))


# Table manipulation

proc createTables*[T: Model](dbConn; obj: T) =
  ## Create tables for `Model`_ and its `Model`_ fields.

  for fld, val in obj[].fieldPairs:
    if val.model.isSome:
        dbConn.createTables(get val.model)

  var colGroups, fkGroups: seq[string]

  for fld, val in obj[].fieldPairs:
    var colShmParts: seq[string]

    colShmParts.add obj.col(fld)

    colShmParts.add typeof(val).dbType

    when val isnot Option:
      colShmParts.add "NOT NULL"

    when obj.dot(fld).hasCustomPragma(pk):
      colShmParts.add "PRIMARY KEY"

    when obj.dot(fld).hasCustomPragma(unique):
      colShmParts.add "UNIQUE"

    if val.isModel:
      fkGroups.add "FOREIGN KEY($#) REFERENCES $#($#)" %
        [obj.col(fld), typeof(get val.model).table, typeof(get val.model).col("id")]

    when obj.dot(fld).hasCustomPragma(fk):
      # Check val is int
      when val isnot int:
        {.fatal: "Pragma fk must be used on an integer field. " & fld & " is not an integer." .}
      else:
        # Check pragma value is Model
        const fkTargetIsModel = obj.dot(fld).getCustomPragmaVal(fk) is Model
        when not fkTargetIsModel:
          # Const string to output error message
          const fkTargetName = $(obj.dot(fld).getCustomPragmaVal(fk))
          {.fatal: "Pragma fk must reference a Model. " & fkTargetName & " is not a Model.".}
        else:
          fkGroups.add "FOREIGN KEY ($#) REFERENCES $#(id)" % [fld, (obj.dot(fld).getCustomPragmaVal(fk)).table]

    colGroups.add colShmParts.join(" ")

  let qry = "CREATE TABLE IF NOT EXISTS $#($#)" % [T.table, (colGroups & fkGroups).join(", ")]

  when defined(normDebug):
    debug qry
  dbConn.exec(sql qry)

# Row manipulation

proc insert*[T: Model](dbConn; obj: var T) =
  ## Insert rows for `Model`_ instance and its `Model`_ fields, updating their ``id`` fields.

  # If `id` is not 0, this object has already been inserted before
  if obj.id != 0:
    return

  for fld, val in obj[].fieldPairs:
    if val.model.isSome:
      var subMod = get val.model
      dbConn.insert(subMod)

  let
    row = obj.toRow()
    phds = "?".repeat(row.len)
    qry = "INSERT INTO $# ($#) VALUES($#)" % [T.table, obj.cols.join(", "), phds.join(", ")]

  when defined(normDebug):
    debug "$# <- $#" % [qry, $row]
  obj.id = dbConn.insertID(sql qry, row).int

proc insert*[T: Model](dbConn; objs: var openArray[T]) =
  ## Insert rows for each `Model`_ instance in open array.

  for obj in objs.mitems:
    dbConn.insert(obj)

proc select*[T: Model](dbConn; obj: var T, cond: string, params: varargs[DbValue, dbValue]) =
  ##[ Populate a `Model`_ instance and its `Model`_ fields from DB.

  ``cond`` is condition for ``WHERE`` clause but with extra features:

  - use ``?`` placeholders and put the actual values in ``params``
  - use `table <model.html#table,typedesc[Model]>`_, \
    `col <model.html#col,T,string>`_, and `fCol <model.html#fCol,T,string>`_ procs \
    instead of hardcoded table and column names
  ]##

  let
    joinStmts = collect(newSeq):
      for grp in obj.joinGroups:
        "LEFT JOIN $# AS $# ON $# = $#" % [grp.tbl, grp.tAls, grp.lFld, grp.rFld]
    qry = "SELECT $# FROM $# $# WHERE $#" % [obj.rfCols.join(", "), T.table, joinStmts.join(" "), cond]

  when defined(normDebug):
    debug "$# <- $#" % [qry, $params]
  let row = dbConn.getRow(sql qry, params)

  if row.isNone:
    raise newException(KeyError, "Record not found")

  obj.fromRow(get row)

proc select*[T: Model](dbConn; objs: var seq[T], cond: string, params: varargs[DbValue, dbValue]) =
  ##[ Populate a sequence of `Model`_ instances from DB.

  ``objs`` must have at least one item.
  ]##

  if objs.len < 1:
    raise newException(ValueError, "``objs`` must have at least one item.")

  let
    joinStmts = collect(newSeq):
      for grp in objs[0].joinGroups:
        "LEFT JOIN $# AS $# ON $# = $#" % [grp.tbl, grp.tAls, grp.lFld, grp.rFld]
    qry = "SELECT $# FROM $# $# WHERE $#" % [objs[0].rfCols.join(", "), T.table, joinStmts.join(" "), cond]

  when defined(normDebug):
    debug "$# <- $#" % [qry, $params]
  let rows = dbConn.getAllRows(sql qry, params)

  if objs.len > rows.len:
    objs.setLen(rows.len)

  for _ in 1..(rows.len - objs.len):
    var obj: T
    new obj
    obj.deepCopy(objs[0])
    objs.add obj

  for i, row in rows:
    objs[i].fromRow(row)

proc selectAll*[T: Model](dbConn; objs: var seq[T]) =
  ##[ Populate a sequence of `Model`_ instances from DB, fetching all rows in the matching table.

  ``objs`` must have at least one item.

  **Warning:** this is a dangerous operation because you don't control how many rows will be fetched.
  ]##

  dbConn.select(objs, "1")

proc update*[T: Model](dbConn; obj: var T) =
  ## Update rows for `Model`_ instance and its `Model`_ fields.

  for fld, val in obj[].fieldPairs:
    if val.model.isSome:
      var subMod = get val.model
      dbConn.update(subMod)

  let
    row = obj.toRow()
    phds = collect(newSeq):
      for col in obj.cols:
        "$# = ?" %  col
    qry = "UPDATE $# SET $# WHERE id = $#" % [T.table, phds.join(", "), $obj.id]

  when defined(normDebug):
    debug "$# <- $#" % [qry, $row]
  dbConn.exec(sql qry, row)

proc update*[T: Model](dbConn; objs: var openArray[T]) =
  ## Update rows for each `Model`_ instance in open array.

  for obj in objs.mitems:
    dbConn.update(obj)

proc delete*[T: Model](dbConn; obj: var T) =
  ## Delete rows for `Model`_ instance and its `Model`_ fields.

  let qry = "DELETE FROM $# WHERE id = $#" % [T.table, $obj.id]

  when defined(normDebug):
    debug qry
  dbConn.exec(sql qry)

  obj = nil

proc delete*[T: Model](dbConn; objs: var openArray[T]) =
  ## Delete rows for each `Model`_ instance in open array.

  for obj in objs.mitems:
    dbConn.delete(obj)


# Transactions

proc rollback* {.raises: RollbackError.} =
  ## Rollback transaction by raising `RollbackError <#RollbackError>`_.

  raise newException(RollbackError, "Rollback transaction.")

template transaction*(dbConn; body: untyped): untyped =
  ##[ Wrap code in DB transaction.

  If an exception is raised, the transaction is rollbacked.

  To rollback manually, call `rollback`_.
  ]##

  let
    beginQry = "BEGIN"
    commitQry = "COMMIT"
    rollbackQry = "ROLLBACK"

  try:
    when defined(normDebug):
      debug beginQry
    dbConn.exec(sql beginQry)

    body

    when defined(normDebug):
      debug commitQry
    dbConn.exec(sql commitQry)

  except:
    when defined(normDebug):
      debug rollbackQry
    dbConn.exec(sql rollbackQry)
    raise
