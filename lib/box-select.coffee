###
  lib/box-select.coffee
  wrap problems when shrinking page
  border should check against longest line contained
  scrollwheel broken
  box not updated on auto-scroll
###

SubAtom = require 'sub-atom'

log = (args...) -> 
  console.log.apply console, ['box-select:'].concat args

class BoxSelect
  
  activate: ->
    @wspace = atom.workspace
    @subs = new SubAtom
    @subs.add atom.commands.add 'atom-text-editor', 
                                'box-select:toggle': => @toggle()
  
  toggle: ->
    if @selectMode or
         not (@editor = @wspace.getActiveTextEditor()) or @editor.isDestroyed()
      @clear()
      return 
    @selectMode = yes
    @getAtomReferences()
    @getPageDims()
    @addBoxEle()
    @createBoxWithAtomSelections()
    @checkPageDims()
    @pane.onDidChangeActiveItem    => @clear()
    document.body.onkeydown  = (e) => @keyDown  e
    document.body.onkeypress = (e) => @keyPress e
    @undoBuffers    = []
    @undoBoxRowCols = []
    @undoIdx = 0
    
  getAtomReferences: ->
    @pane       = @wspace.getActivePane()
    @editorView = atom.views.getView @editor
    @editorComp = @editorView.component
    @buffer     = @editor.getBuffer()
  
  getElement:  (sel) -> @editorView.shadowRoot.querySelector sel
  getElements: (sel) -> @editorView.shadowRoot.querySelectorAll sel
  
  getPageDims: (editRect, chrWid, chrHgt) ->
    @chrWid = (chrWid ? @editor.getDefaultCharWidth()  )
    @chrHgt = (chrHgt ? @editor.getLineHeightInPixels())
    {left: @editorPageX, top: @editorPageY, width: @editorWtotal, height: @editorHtotal} =
                   (editRect ? @editorView.getBoundingClientRect())
    @hBar = @getElement '.horizontal-scrollbar'
    @vBar = @getElement '.vertical-scrollbar'
    @editorW = @editorWtotal - 
      (if (@vBarVis = (@vBar.display isnt 'none')) then @vBar.offsetWidth  else 0)
    @editorH = @editorHtotal - 
      (if (@hBarVis = (@hBar.display isnt 'none')) then @hBar.offsetHeight else 0)

  getScrollOfs: (update) ->
    if update or not @scrollOfs
      for @scrollRefEle in @getElements '.line'
        row = +@scrollRefEle.getAttribute 'data-screen-row'
        {left: linePageX, top: linePageY} = @scrollRefEle.getBoundingClientRect()
        if 0 <= (linePageY - @editorPageY) < 2 * @chrHgt then break
      @scrollRefEleOfs = @scrollRefEle.offsetTop
      @scrollOfs = [@editorPageX - linePageX, @editorPageY - (linePageY - row * @chrHgt)]
    @scrollOfs  
    
  checkPageDims: ->
    if not @editorView then return
    {left, top, width, height} = (editRect = @editorView.getBoundingClientRect())
    if  @editorPageX  isnt left   or
        @editorPageY  isnt top    or
        @editorWtotal isnt width  or
        @editorHtotal isnt height or
        @chrWid       isnt (chrWid = @editor.getDefaultCharWidth()  ) or
        @chrHgt       isnt (chrHgt = @editor.getLineHeightInPixels()) or
        @vBarVis      isnt (@vBar.display isnt 'none') or
        @hbarVis      isnt (@hBar.display isnt 'none') or
        @scrollRefEle.offsetTop isnt @scrollRefEleOfs
      @getPageDims editRect, chrWid, chrHgt
      @getScrollOfs yes
      @refreshCoverPos()
      @refreshBoxPos()
      @refreshTxtEditorPos()
      setTimeout (=> @checkPageDims()), 200
      return
    setTimeout (=> @checkPageDims()), 200
  
  edit2textXY: (x1, y1, x2, y2) ->
    [scrollOfsX, scrollOfsY] = @getScrollOfs()
    [x1 + scrollOfsX, y1 + scrollOfsY
     x2 + scrollOfsX, y2 + scrollOfsY]
       
  text2editXY: (x1, y1, x2, y2) ->
    [scrollOfsX, scrollOfsY] = @getScrollOfs()
    [x1 - scrollOfsX, y1 - scrollOfsY
     x2 - scrollOfsX, y2 - scrollOfsY]
  
  createBoxWithAtomSelections: ->
    row1 = col1 = +Infinity
    row2 = col2 = -Infinity
    for sel in @editor.getSelections()
      range = sel.getBufferRange()
      row1 = Math.min row1, range.start.row,    range.end.row
      col1 = Math.min col1, range.start.column, range.end.column
      row2 = Math.max row2, range.start.row,    range.end.row
      col2 = Math.max col2, range.start.column, range.end.column
    @setBoxByRowCol row1, col1, row2, col2
    for selection in @editor.getSelections()
      selection.destroy()
    @editor.getLastCursor().setVisible no
    
  ensureScreenHgt: (scrnRows) ->
    loop
      endScrnRange = @editor.screenRangeForBufferRange [[9e9,9e9],[9e9,9e9]]
      if endScrnRange.end.row >= scrnRows - 1 then return
      @editor.setTextInBufferRange [[9e9,9e9],[9e9,9e9]], '\n'

  ensureLineWid: (bufRow, length) ->
    lineLen = @editor.lineTextForBufferRow(bufRow).length
    if lineLen < length
      pad = ' '; for i in [1...length-lineLen] then pad += ' '
      @editor.setTextInBufferRange [[bufRow,lineLen],[bufRow,length]], pad
  
  editBox: (cmd, text, addToUndo = yes) ->
    # log '@editBox', {cmd, text}
    if addToUndo
      oldBufferText = @editor.getText()
      oldRowCol = [row1, col1, row2, col2] = @getBoxRowCol()
    
    clipHgt = 0
    if cmd in ['paste', 'setText']  
      clipTxt = (if cmd is 'paste' then atom.clipboard.read() else text)        
      clipLines = clipTxt.split '\n'
      if clipLines[clipLines.length-1].length is 0
        clipLines = clipLines[0..-2]
      clipHgt = clipLines.length
      clipWidth = 0
      for clipLine in clipLines 
        clipWidth = Math.max clipWidth, clipLine.length
      for clipRow in [0...clipHgt]
        while clipLines[clipRow].length < clipWidth then clipLines[clipRow] += ' '
      blankClipLine = ''
      while blankClipLine.length < clipWidth then blankClipLine += ' '
      getClipLine = (clipRow) ->
        (if clipRow < clipHgt then clipLines[clipRow] else blankClipLine)
    
    if cmd not in ['copy', 'getText']
      @ensureScreenHgt Math.max row2, row1 + clipHgt
    
    dbg = 0
    screenRow = row1
    boxRow = 0; boxLine = ''
    if cmd is 'fill' then for i in [col1...col2] then boxLine += text
    boxHgt = row2 - row1 + 1
    copyText = ''; lastBufRow = null
    
    while boxRow <= boxHgt-1 or
          cmd in ['paste', 'setText'] and boxRow <= clipHgt-1
      bufRange = 
        @editor.bufferRangeForScreenRange [[screenRow,col1],[screenRow,col2]]
      bufRow = bufRange.start.row
      @ensureLineWid bufRow, col1
      bufRange = 
        @editor.bufferRangeForScreenRange [[screenRow,col1],[screenRow,col2]]
      screenRow++
      if ++dbg > 30 then log 'oops'; return
      if bufRow is lastBufRow then continue
      lastBufRow = bufRow
      
      if cmd in ['paste', 'setText']
        @editor.setTextInBufferRange bufRange, getClipLine boxRow
      else if boxRow <= boxHgt-1
        if cmd in ['copy', 'cut', 'getText'] 
          copyText += @editor.getTextInBufferRange(bufRange) + '\n'
        if cmd in ['cut', 'del', 'fill']
          @editor.setTextInBufferRange bufRange, boxLine
      boxRow++
    if cmd is 'copy' then atom.clipboard.write copyText
    
    newCol2 = switch cmd
      when 'paste', 'setText' then col1 + clipWidth
      when 'fill', 'copy', 'setText', 'getText' then col2
      else col1
    @setBoxByRowCol row1, col1, screenRow-1, newCol2
    
    if addToUndo then @addToUndo oldBufferText, oldRowCol
      
    copyText
    
  selectAll: ->
    allRange = @editor.screenRangeForBufferRange [[0,0],[9e9,9e9]]
    row2 = allRange.end.row
    col2 = 0
    for row in [0...@editor.getLineCount()]
      col2 = Math.max col2, @editor.lineTextForBufferRow(row).length
    @setBoxByRowCol 0, 0, row2, col2
    
  openTextEditor: ->
    text = @editBox 'getText'
    [row1, col1, row2, col2] = @getBoxRowCol()
    t = @textEditor = document.createElement 'textArea'
    t.id = 'boxsel-txtarea'
    t   .classList.add 'native-key-bindings'
    @box.classList.add 'native-key-bindings'
    t.rows = row2-row1+1; t.cols = col2-col1-1
    t.spellcheck = yes;   t.wrap = 'hard'
    t.value = text
    [x1, y1, x2, y2] = @getBoxXY()     
    w = Math.max x2 - x1 + 30, 120
    h = Math.max y2 - y1 + 30,  40
    ts = t.style
    bs = @box.style
    es = window.getComputedStyle @editorView
    ts.left            = bs.left
    ts.top             = bs.top
    ts.width           = w + 'px'
    ts.height          = h + 'px'
    ts.fontFamily      = es.fontFamily
    ts.backgroundColor = es.backgroundColor
    ts.color           = es.color
    ts.fontSize        = es.fontSize
    ts.lineHeight      = es.lineHeight
    @cover.appendChild t
    @setBoxVisible no
    
  refreshTxtEditorPos: ->
    if @textEditor
      bs = @box.style
      ts = @textEditor.style
      ts.left = bs.left
      ts.top  = bs.top
  
  closeTextEditor: ->
    @setBoxVisible yes
    if @textEditor 
      @addToUndo @editBox('getText'), @getBoxRowCol()
      @editBox 'setText', @textEditor.value
      @cover.removeChild @textEditor
      @textEditor = null

  boxToAtomSelections: ->
    oldSelection = @editor.getLastSelection()
    [row1, col1, row2, col2] = @getBoxRowCol()
    for row in [row1..row2]
      @editor.addSelectionForBufferRange [[row, col1], [row, col2]]
    oldSelection.destroy()
          
  addBoxEle: ->
    c = @cover = document.createElement 'div'
    c.id = 'boxsel-cover'
    cs = c.style
    cs.left   = @editorPageX  + 'px'
    cs.top    = @editorPageY  + 'px'
    cs.width  = @editorW      + 'px'
    cs.height = @editorH      + 'px'
    setTimeout (-> cs.cursor = 'crosshair'), 50
    b = @box = document.createElement 'div'
    b.id     = 'boxsel-box'
    document.body.appendChild c
    c.appendChild b
    c.onmousedown = (e) => @mouseEvent(e)
    c.onmousemove = (e) => @mouseEvent(e)
    c.onmouseup   = (e) => @mouseEvent(e)
  
  refreshCoverPos: ->
    cs = @cover.style
    cs.left   = @editorPageX  + 'px'
    cs.top    = @editorPageY  + 'px'
    cs.width  = @editorW      + 'px'
    cs.height = @editorH      + 'px'
    
  removeBoxEle: ->
    if @cover 
      document.body.removeChild @cover
      @cover.removeChild @box
      @cover = @box = null
      
  setBoxVisible: (@boxVisible) ->
    @box?.style.visibility = 
      (if @boxVisible then 'visible' else 'hidden')

  setBoxByXY: (x1, y1, x2, y2, haveRowCol) ->
    if (dot = (x2 is 'dot')) then [x2, y2] = [x1, y1]
    x1 = Math.round(x1/@chrWid) * @chrWid
    y1 = Math.round(y1/@chrHgt) * @chrHgt
    x2 = Math.round(x2/@chrWid) * @chrWid
    y2 = Math.round(y2/@chrHgt) * @chrHgt
    [editX1, editY1, editX2, editY2] = @text2editXY x1, y1, x2, y2
    @initEditX1 ?= x1
    @initEditY1 ?= y1
    if editX1 > editX2 then [editX1, editX2] = [editX2, editX1]
    if editY1 > editY2 then [editY1, editY2] = [editY2, editY1]
    bs = @box.style
    bs.left = editX1 + 'px'
    bs.top  = editY1 + 'px'
    if dot or (editX2-editX1) > 0 or (editY2-editY1) > 0
      bs.width  = (editX2-editX1) + 'px'
      bs.height = (editY2-editY1) + 'px'
    else
      bs.width  = '0'
      bs.height = @chrHgt + 'px'
    if not haveRowCol
      botRow = @buffer.getLastRow()
      @boxRow1 = Math.max      0,  Math.round y1 / @chrHgt
      @boxCol1 = Math.max      0,  Math.round x1 / @chrWid
      @boxRow2 = Math.min botRow, (Math.round y2 / @chrHgt) - 1
      @boxCol2 =                   Math.round x2 / @chrWid
    @setBoxVisible yes

  setBoxByRowCol: (@boxRow1, @boxCol1, @boxRow2, @boxCol2) ->
    @setBoxByXY @boxCol1 * @chrWid,  @boxRow1    * @chrHgt, 
                @boxCol2 * @chrWid, (@boxRow2+1) * @chrHgt, yes
  
  refreshBoxPos: ->
    @setBoxByRowCol @boxRow1, @boxCol1, @boxRow2, @boxCol2
    
  getBoxXY: -> 
    if not (s = @box?.style) then return [0,0,0,0]
    style2dim = (attr) -> +(s[attr].replace 'px', '')
    editX1 = style2dim 'left'; editY1 = style2dim 'top'
    editX2 = editX1 + style2dim 'width'
    editY2 = editY1 + style2dim 'height'
    @edit2textXY editX1, editY1, editX2, editY2
    
  getBoxRowCol: -> [@boxRow1, @boxCol1, @boxRow2, @boxCol2]

  addToUndo: (txt, rowcol) ->
    if @undoIdx is 0 or txt isnt @undoBuffers[@undoIdx-1]
      @undoBuffers[@undoIdx]    = txt
      @undoBoxRowCols[@undoIdx] = rowcol
      @undoIdx++
      @undoBuffers = @undoBuffers[0...@undoIdx]
      
  undo: ->
    if @undoIdx > 0
      @undoBuffers[@undoIdx]    = @editor.getText()
      @undoBoxRowCols[@undoIdx] = @getBoxRowCol()
      --@undoIdx
      @editor.setText @undoBuffers[@undoIdx]
      @setBoxByRowCol @undoBoxRowCols[@undoIdx]...

  redo: ->
    if @undoIdx < @undoBuffers.length-1 
      @undoIdx++
      @editor.setText @undoBuffers[@undoIdx]
      @setBoxByRowCol @undoBoxRowCols[@undoIdx]...
  
  chkScrollBorders: (editX, editY) ->
    now = Date.now()
    if @chkScrlBrdrTimeout 
      clearTimeout @chkScrlBrdrTimeout
      @chkScrlBrdrTimeout = null
    else
      @chkScrollBordersStart = now
    if (not (6 * @chrWid < editX < @editorPageW - 2 * @chrWid) or
        not (2 * @chrHgt < editY < @editorPageH - 2 * @chrHgt)) and @mouseIsDown
      [ofsX, ofsY] = @getScrollOfs()
      row = (Math.round (editY + ofsY) / @chrHgt) - 1
      col =  Math.round (editX + ofsX) / @chrWid
      @editor.scrollToScreenPosition [row, col]
      @getPageDims()
      @refreshBoxPos()
      if now < @chkScrollBordersStart + 2e3
        @chkScrlBrdrTimeout = 
          setTimeout (=> @chkScrollBorders editX, editY), 100
    
  mouseEvent: (e) ->
    if e.target is @textEditor then return
    if not @selectMode or not @editor or @editor.isDestroyed()
      @clear()
      return
    switch e.type
      when 'mousedown'
        @mouseIsDown = yes
        if @initEditX1? and e.shiftKey
          editX2 = e.pageX - @editorPageX
          editY2 = e.pageY - @editorPageY
          @setBoxByXY \
            @edit2textXY @initEditX1, @initEditY1, editX2, editY2
        else
          @initEditX1 = e.pageX - @editorPageX
          @initEditY1 = e.pageY - @editorPageY
          [initX1, initY1] = 
              @edit2textXY @initEditX1, @initEditY1, 0, 0
          @setBoxByXY initX1, initY1, 'dot', null
      
      when 'mousemove' 
        if not @mouseIsDown then return
        editX2 = e.pageX - @editorPageX
        editY2 = e.pageY - @editorPageY
        [x1, y1, x2, y2] = @edit2textXY @initEditX1, @initEditY1, editX2, editY2
        @setBoxByXY x1, y1, x2, y2
        @chkScrollBorders editX2, editY2
        
      when 'mouseup'
        if not @mouseIsDown then return
        @mouseIsDown = no
        editX2 = e.pageX - @editorPageX
        editY2 = e.pageY - @editorPageY
        @setBoxByXY \
            @edit2textXY(@initEditX1, @initEditY1, editX2, editY2)...
      
  unicodeChr: (e, chr) ->
    # log 'unicodeChr', chr.charCodeAt(0), '"'+chr+'"'
    if chr.charCodeAt(0) >= 32
      @editBox 'fill', chr
    e.stopPropagation()
    e.preventDefault()

  keyAction: (e, codeStr) ->    
    if e.metaKey  then codeStr = 'Meta-'  + codeStr
    if e.shiftKey then codeStr = 'Shift-' + codeStr
    if e.altKey   then codeStr = 'Alt-'   + codeStr
    if e.ctrlKey  then codeStr = 'Ctrl-'  + codeStr
    
    log 'keyAction', codeStr
    switch codeStr
      when 'Ctrl-X'              then @editBox 'cut'
      when 'Ctrl-C'              then @editBox 'copy'
      when 'Ctrl-V'              then @editBox 'paste'
      when 'Backspace', 'Delete' then @editBox 'del'
      when 'Ctrl-A'              then @selectAll()
      when 'Ctrl-Z'              then @undo()
      when 'Ctrl-Y'              then @redo()
      when 'Enter'                
        if @textEditor then return
        else @openTextEditor()
      when 'Escape', 'Tab' 
        if @textEditor then @closeTextEditor()
        else @clear()
      else 
        log codeStr + ' passed on to Atom'
        return
    e.stopPropagation()
    e.preventDefault()
    
  keyDown: (e) ->
    keyId = e.keyIdentifier
    if @textEditor and keyId not in ['U+0009', 'U+001B'] then return
    if not @selectMode or not @editor or @editor.isDestroyed()
      @clear()
      return
    if keyId[0..1] is 'U+'
      code = parseInt keyId[2..5], 16
      switch code
        when   8 then codeStr = 'Backspace'
        when   9 then codeStr = 'Tab'
        when  10 then codeStr = 'LineFeed'
        when  13 then codeStr = 'Return'
        when  27 then codeStr = 'Escape'
        when 127 then codeStr = 'Delete'
        else 
          if (e.metaKey or e.altKey or e.ctrlKey)
            if (32 <= code < 127)
              @keyAction e, String.fromCharCode code
            else
              e.stopPropagation()
              e.preventDefault()
          return
      if codeStr then @keyAction e, codeStr
      return
    @keyAction e, keyId
    
  keyPress: (e) ->
    if @textEditor then return
    if not @selectMode or
       not @editor or @editor.isDestroyed()
      @clear()
      return
    chr = String.fromCharCode e.charCode
    # log 'keyPress', e.keyCode, e.charCode, '"'+chr+'"', (e.ctrlKey or e.altKey or e.metaKey)
    if e.ctrlKey or e.altKey or e.metaKey
      @keyAction e, chr.toUpperCase()
    else
      @unicodeChr e, chr
      
  clear: ->
    haveEditor = (@editor and not @editor.isDestroyed() and 
                    @pane and not   @pane.isDestroyed())
    @boxToAtomSelections() if haveEditor
    @removeBoxEle()
    @mouseIsDown = @selectMode = no
    @undoBuffers = @undoBoxRowCols = null
    @undoIdx = 0
    @pane?.activate() if haveEditor
    @pane = @editorView = @editorComp = @buffer = null

  deactivate: ->
    @clear()
    @subs.dispose()  

module.exports = new BoxSelect

