import macros

proc exportIdent(ident: NimNode, exports: bool): NimNode {.compileTime.} =
  if exports: nnkPostfix.newTree(newIdentNode("*"), ident) else: ident

macro implementInterface(interfaceName: typed, exports: static[bool]) : untyped =
  let
    interfaceNameStr = $interfaceName.symbol
    vtableSymbol = interfaceName.symbol.getImpl[2][2][1][1][0]
    vtableRecordList = vtableSymbol.symbol.getImpl[2][2]

  let
    objectConstructor = nnkObjConstr.newTree(vtableSymbol)
  
  echo "Vtable", vtableRecordList.repr
  for identDefs in vtableRecordList:
    let
      methodName = identDefs[0]
      params = identDefs[1][0]
      lambdaBody = nnkPar.newTree quote do:
        `methodName`(cast[var T](this))
      
    echo lambdaBody.treeRepr

    for i in 2 ..< len(params):
      let param = params[i]
      param.expectKind(nnkIdentDefs)
      for j in 0 .. len(param) - 3:
        lambdaBody[0].add param[j]
    
    if lambdaBody[0].len == 1:
      lambdaBody[0] = lambdaBody[0][0]

    methodName.expectKind nnkIdent

    objectConstructor.add nnkExprColonExpr.newTree(
      methodName,
      nnkLambda.newTree(
        newEmptyNode(),newEmptyNode(),newEmptyNode(),
        params.copy,
        newEmptyNode(),newEmptyNode(),
        newStmtList(
          nnkMixinStmt.newTree(methodName),
          lambdaBody
        )
      )
    )

  let
    getVtableReturnStatement =
      nnkReturnStmt.newTree(newCall("addr", newIdentNode("theVtable")))
    globalVtableIdent = newIdentNode("theVtable")
    getVtableProcIdent = newIdentNode("get" & interfaceNameStr & "Vtable")
    vtableType = newIdentNode(interfaceNameStr & "Vtable")
    getVtableProcDeclaration = quote do:
      proc `getVtableProcIdent`[T](): ptr `vtableType` =
        var `globalVtableIdent` {.global.} = `objectConstructor`
        `getVtableReturnStatement`

  result = newStmtList()
  result.add getVtableProcDeclaration

  let castIdent = exportIdent(newIdentNode("to" & $interfaceName.symbol), exports)

  result.add quote do:
    converter `castIdent`[T](this: ptr T) : `interfaceName` = `interfaceName`(
      objet : this,
      vtable : `getVtableProcIdent`[T]()
    )

  result.add quote do:
    converter `castIdent`[T](this: var T) : `interfaceName` = `interfaceName`(
      objet : this.addr,
      vtable : `getVtableProcIdent`[T]()
    )

  result.add quote do:
    converter `castIdent`(this: `interfaceName`): `interfaceName` = this

  when defined(interfacedebug):
    echo result.repr


macro createInterface*(name : untyped, methods : untyped) : untyped =
  if name.kind != nnkPrefix: name.expectKind nnkIdent

  let
    exports = name.kind == nnkPrefix
    cleanedName = if exports: name[1] else: name    
    nameStr = $cleanedName.ident
    markedName = if exports: newTree(nnkPostfix, newIdentNode("*"), cleanedName) else: name  

    vtableRecordList = nnkRecList.newTree
    vtableIdent = newIdentNode(nameStr & "Vtable")
    vtableTypeDef = nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        vtableIdent,
        newEmptyNode(),
        nnkObjectTy.newTree(
          newEmptyNode(),
          newEmptyNode(),
          vtableRecordList
        )
      )
    )

  var newMethods = newSeq[NimNode]()

  for meth in methods:
    meth.expectKind(nnkProcDef)
    let
      methodIdent = if meth[0].kind == nnkPostfix: meth[0][1] else: meth[0]
      params = meth[3]
      thisParam = params[1]
      thisIdent = thisParam[0]
      thisType  = thisParam[1]

    if thisType != cleanedName:
      error thisType.repr & " != " & cleanedName.repr

    let vtableEntryParams = params.copy
    vtableEntryParams[1][1] = newIdentNode("pointer")

    vtableRecordList.add(
      nnkIdentDefs.newTree(
        methodIdent,
        nnkProcTy.newTree(
          vtableEntryParams,
          newEmptyNode(),
        ),
        newEmptyNode()
      )
    )

    let call = nnkCall.newTree(
      nnkDotExpr.newTree( nnkDotExpr.newTree(thisIdent, newIdentNode("vtable")), methodIdent  ),
      nnkDotExpr.newTree( thisIdent, newIdentNode("objet") ),
    )

    for i in 2 ..< len(params):
      let param = params[i]
      param.expectKind(nnkIdentDefs)
      for j in 0 .. len(param) - 3:
        call.add param[j]

    meth[6] = nnkStmtList.newTree(call)

    newMethods.add(meth)

  result = newStmtList()
  result.add(vtableTypeDef)
  result.add quote do:
    type `markedName` = object
      objet : pointer
      vtable: ptr `vtableIdent`

  for meth in newMethods:
    result.add meth

  result.add newCall(bindSym"implementInterface", cleanedName, newIdentNode(if exports: "true" else: "false"))

  when defined(interfacedebug):
    echo result.repr
