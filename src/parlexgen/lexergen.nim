import std/[macros, genasts]

import ./private/utils, ./common
import ./private/lexim/lexim


type
  LexingError* = ref object of CatchableError
    pos*: int

macro makeLexer*(head,body: untyped): untyped =
  body.expectKindError(nnkStmtList, "expected list of rules")
  
  let (procIdent, tokenType) = getProcMeta(head)

  let
    code   = genSym(nskParam, "code")
    state  = genSym(nskParam, "state")
    pos    = newDotExpr(state, ident"pos")
    oldPos = ident"pos"
    line   = ident"line"
    col    = ident"col"
    match  = ident"match"
    rules  = genSym(nskVar, "rules")
    matchingBlock = genSym(nskLabel, "matching")

  proc genAddRule(rule: NimNode, captures: varargs[NimNode]): NimNode =
    rule.expectKindError({nnkCall, nnkCommand}, "expected pattern with token generation code")
    # TODO: verify rule[0] is string (not neccesary literal)
    let pattern = rule[0]
    let action  = rule[1]
    action.expectKind(nnkStmtList)

    let matchBody =
      if len(action) == 1 and action[0].kind == nnkContinueStmt:
        newStmtList(nnkBreakStmt.newTree(matchingBlock))
      else:
        genAst(action, code, state, match, oldPos):
          let match = code[oldPos ..< state.pos]
          return some(action)

    let genAstCall = quote do:
      genAst(`oldPos`=ident"pos", `line`=ident"line", `col`=ident"col")
    for capture in captures:
      genAstCall.add capture
    genAstCall.add matchBody

    newCall(ident"add", rules,
      nnkTupleConstr.newTree(pattern, genAstCall)
    )

  var rulesSeqDef = newStmtList(quote do:
    var `rules`: seq[(string, NimNode)]
  )

  for rule in body:

    # -- loops of rules: --

    if rule.kind == nnkForStmt:
      let
        elem = rule[0]
        vals = rule[1]
        body = rule[2]

      body.expectKind(nnkStmtList)

      var loopBody = newStmtList()
      for rule in body:
        loopBody.add genAddRule(rule, elem)

      rulesSeqDef.add nnkForStmt.newTree(elem, vals, loopBody)

      continue

    # -- plain rules: --
    rulesSeqDef.add genAddRule(rule)

  result = quote do:
    proc `procIdent`(`code`: string, `state`: var LexerState): Option[`tokenType`] =
      while `state`.pos < len(`code`):
        let `oldPos` = `state`.pos
        let `line`   = `state`.line
        let `col`    = `state`.col
        block `matchingBlock`:
          macro impl(c: untyped) =
            `rulesSeqDef`
            leximMatch(c, quote do: `pos`, `rules`)
          impl(`code`)
          raise LexingError(pos: `oldPos`, msg: "lexing failed")
      return none(`tokenType`)