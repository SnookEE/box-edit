###
  lib/box-select.coffee
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
    @getDisplayConstants()
    @createBoxWithAtomSelections()
    @pane.onDidChangeActiveItem    => @clear()
    document.body.onkeydown  = (e) => @keyDown  e
    document.body.onkeypress = (e) => @keyPress e
    @undoBuffers    = []
    @undoBoxRowCols = []
    
  getAtomReferences: ->
    @pane       = @wspace.getActivePane()
    @editorView = atom.views.getView @editor
    @editorComp = @editorView.component
    @buffer     = @editor.getBuffer()
    
  getDisplayConstants: ->
    @chrWid     = @editor.getDefaultCharWidth()
    @chrHgt     = @editor.getLineHeightInPixels()
    {left: @editorPageX, top: @editorPageY, width: @editorW, height: @editorH} =
                   @editorView.getBoundingClientRect()
    {left, top}  = @editorComp.pixelPositionForMouseEvent clientX:0, clientY:0
    @textPageX   = -left
    @textPageY   = -top
    @textOfsX    = @textPageX - @editorPageX  
    @textOfsY    = @textPageY - @editorPageY 
    
  createBoxWithAtomSelections: ->
    row1 = col1 = +Infinity
    row2 = col2 = -Infinity
    for sel in @editor.getSelections()
      range = sel.getBufferRange()
      row1 = Math.min row1, range.start.row,    range.end.row
      col1 = Math.min col1, range.start.column, range.end.column
      row2 = Math.max row2, range.start.row,    range.end.row
      col2 = Math.max col2, range.start.column, range.end.column
    @addBoxEle()
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
  
  bufferOperation: (cmd, chr) ->
    # log 'bufferOperation', {cmd, chr}
    oldBufferText = @editor.getText()
    oldRowCol = [row1, col1, row2, col2] = @getBoxRowCol()
    
    clipHgt = 0
    if cmd is 'paste'  
      clipTxt   = atom.clipboard.read()
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
    
    if cmd isnt 'copy'
      @ensureScreenHgt Math.max row2, row1 + clipHgt
    
    dbg = 0
    screenRow = row1
    boxRow = 0; boxLine = ''
    if cmd is 'fill' then for i in [col1...col2] then boxLine += chr
    boxHgt = row2 - row1 + 1
    copyText = ''; lastBufRow = null
    
    while boxRow <= boxHgt-1 or
          cmd is 'paste' and boxRow <= clipHgt-1
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
      
      if cmd is 'paste' 
        @editor.setTextInBufferRange bufRange, getClipLine boxRow
      else if boxRow <= boxHgt-1
        if cmd in ['copy', 'cut'] 
          copyText += @editor.getTextInBufferRange(bufRange) + '\n'
        if cmd in ['cut', 'del', 'fill']
          # log 'bufRange cut, del, fill', bufRange, boxLine, @editor.getTextInBufferRange(bufRange)
          @editor.setTextInBufferRange bufRange, boxLine
      boxRow++
    
    if cmd is 'copy' then atom.clipboard.write copyText
    
    newCol2 = switch cmd
      when 'paste'        then col1 + clipWidth
      when 'fill', 'copy' then col2
      else col1
    @setBoxByRowCol row1, col1, screenRow-1, newCol2
    
    if @editor.getText() isnt oldBufferText
      @undoBuffers.push oldBufferText
      @undoBoxRowCols.push oldRowCol
    
  boxToAtomSelections: ->
    oldSelection = @editor.getLastSelection()
    [row1, col1, row2, col2] = @getBoxRowCol()
    for row in [row1..row2]
      @editor.addSelectionForBufferRange [[row, col1], [row, col2]]
    oldSelection.destroy()
          
  addBoxEle: ->
    c = @cover = document.createElement 'div'
    c.id = 'boxsel-cover'
    s = c.style
    s.left   = @editorPageX + 'px'
    s.top    = @editorPageY + 'px'
    s.width  = @editorW + 'px'
    s.height = @editorH + 'px'
    setTimeout (-> s.cursor = 'crosshair'), 50
    b = @box = document.createElement 'div'
    b.id     = 'boxsel-box'
    document.body.appendChild c
    c.appendChild b
    c.onmousedown = (e) => @mouseEvent(e)
    c.onmousemove = (e) => @mouseEvent(e)
    c.onmouseup   = (e) => @mouseEvent(e)
  
  removeBoxEle: ->
    if @cover 
      document.body.removeChild @cover
      @cover.removeChild @box
      @cover = @box = null
      
  setBoxVisible: (@boxVisible) ->
    @box?.style.visibility = 
      (if @boxVisible then 'visible' else 'hidden')

  setBoxByXY: (x1, y1, x2, y2, snap2grid = yes) ->
    # log 'setBoxByXY', {x1, y1, x2, y2}
    if not (s = @box?.style) then return
    @initX1 ?= x1
    @initY1 ?= y1
    if (dot = (x2 is 'dot'))
      x2 = x1
      y2 = y1
    if snap2grid
      x1 = Math.round(x1/@chrWid) * @chrWid
      y1 = Math.round(y1/@chrHgt) * @chrHgt
      x2 = Math.round(x2/@chrWid) * @chrWid
      y2 = Math.round(y2/@chrHgt) * @chrHgt
    if x1 > x2 then [x1, x2] = [x2, x1]
    if y1 > y2 then [y1, y2] = [y2, y1]
    s.left = (x1 + @textOfsX) + 'px'
    s.top  = (y1 + @textOfsY) + 'px'
    if dot or (x2-x1) > 0 or (y2-y1) > 0
      s.width  = (x2-x1) + 'px'
      s.height = (y2-y1) + 'px'
    else
      s.width  = '0'
      s.height = @chrHgt + 'px'
    @setBoxVisible yes

  setBoxByRowCol: (row1, col1, row2, col2) ->
    # log 'setBoxByRowCol', {row1, col1, row2, col2}
    @setBoxByXY col1 * @chrWid,  row1    * @chrHgt, 
                col2 * @chrWid, (row2+1) * @chrHgt, no

  getBoxRowCol: -> 
    if not (s = @box?.style) then return [0,0,0,0]
    style2dim = (attr) -> +(s[attr].replace 'px', '')
    x1 = style2dim('left') - @textOfsX
    y1 = style2dim('top')  - @textOfsY
    x2 = x1 + style2dim 'width'
    y2 = y1 + style2dim 'height'
    botRow = @buffer.getLastRow()
    row1 = Math.max      0,  Math.round y1 / @chrHgt
    col1 = Math.max      0,  Math.round x1 / @chrWid
    row2 = Math.min botRow, (Math.round y2 / @chrHgt) - 1
    col2 =                   Math.round x2 / @chrWid
    # log 'getBoxRowCol', {row1, col1, row2, col2}
    [row1, col1, row2, col2]

  mouseEvent: (e) ->
    if not @selectMode or not @editor or @editor.isDestroyed()
      @clear()
      return
    
    switch e.type
      when 'mousedown'
        @mouseIsDown = yes
        if @initX1? and e.shiftKey
          x2 = e.pageX - @textPageX
          y2 = e.pageY - @textPageY
          @setBoxByXY @initX1, @initY1, x2, y2
        else
          @initX1 = e.pageX - @textPageX
          @initY1 = e.pageY - @textPageY
          @setBoxByXY @initX1, @initY1, 'dot' 
      
      when 'mousemove' 
        if not @mouseIsDown then return
        x2 = e.pageX - @textPageX
        y2 = e.pageY - @textPageY
        @setBoxByXY @initX1, @initY1, x2, y2
      
      when 'mouseup'
        if not @mouseIsDown then return
        @mouseIsDown = no
        x2 = e.pageX - @textPageX
        y2 = e.pageY - @textPageY
        @setBoxByXY @initX1, @initY1, x2, y2

  unicodeChr: (e, chr) ->
    # log 'unicodeChr', chr.charCodeAt(0), '"'+chr+'"'
    if chr.charCodeAt(0) >= 32
      @bufferOperation 'fill', chr
    e.stopPropagation()
    e.preventDefault()

  keyAction: (e, codeStr) ->    
    if e.metaKey  then codeStr = 'Meta-'  + codeStr
    if e.shiftKey then codeStr = 'Shift-' + codeStr
    if e.altKey   then codeStr = 'Alt-'   + codeStr
    if e.ctrlKey  then codeStr = 'Ctrl-'  + codeStr
    
    # log 'keyAction', codeStr
    switch codeStr
      when 'Ctrl-X'              then @bufferOperation 'cut'
      when 'Ctrl-C'              then @bufferOperation 'copy'
      when 'Ctrl-V'              then @bufferOperation 'paste'
      when 'Backspace', 'Delete' then @bufferOperation 'del'
      when 'Escape'              then @clear()
      when 'Ctrl-Z'  
        if (oldBuf = @undoBuffers.pop())
          @editor.setText oldBuf
          @setBoxByRowCol @undoBoxRowCols.pop()...
      # when 'Ctrl-S'              then return
      else 
        log codeStr + ' key not used'
        return
    e.stopPropagation()
    e.preventDefault()

  keyDown: (e) ->
    if not @selectMode or not @editor or @editor.isDestroyed()
      @clear()
      return
    # log 'keyDown', e.keyIdentifier
    keyId = e.keyIdentifier
    if keyId[0..1] is 'U+'
      code = parseInt keyId[2..5], 16
      # log 'u code', code
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
    @pane?.activate() if haveEditor
    @pane = @editorView = @editorComp = @buffer = null

  deactivate: ->
    @clear()
    @subs.dispose()  

module.exports = new BoxSelect

