#!/usr/bin/env coffee

##
# lua-distiller
# https://github.com/yi/node-lua-distiller
#
# Copyright (c) 2014 yi
# Licensed under the MIT license.
##

pkg = require "../package"
p = require "commander"
## cli parameters
p.version(pkg.version)
  .option('-o, --output [VALUE]', 'output directory')
  .option('-i, --input [VALUE]', 'path to main entrance coffee file')
  .option('-x, --excludes [VALUE]', 'package names to be excluded, separated by: ","')
  .option('-m, --minify', 'minify merged lua file by LuaSrcDiet')
  .option('-s, --nostring', 'Turn strings into byte by Hipreme')
  .option('-sc, --scrabble', 'Turn function declarations into _HP[COUNT](And counting) by Hipreme')
  .option('-j, --luajitify', 'compile merged lua file into luajit binary')
  .parse(process.argv)

EXTNAME = ".lua"

COMMENT_MARK = "--"

BASE_FILE_PATH = ""

HR = "\n\n---------------------------------------\n\n\n"

DISTILLER_HEAD = """
if __DISTILLER == nil then
  __DISTILLER = nil
  __DISTILLER = {
    FACTORIES = { },
    __nativeRequire = require,
    require = function(id)
      assert(type(id) == "string", "require invalid id:" .. tostring(id))
      if package.loaded[id] then
        return package.loaded[id]
      end
      if __DISTILLER.FACTORIES[id] then
        local func = __DISTILLER.FACTORIES[id]
        package.loaded[id] = func(__DISTILLER.require) or true
        return package.loaded[id]
      end
      return __DISTILLER.__nativeRequire(id)
    end,
    define = function(self, id, factory)
      assert(type(id) == "string", "invalid id:" .. tostring(id))
      assert(type(factory) == "function", "invalid factory:" .. tostring(factory))
      if package.loaded[id] == nil and self.FACTORIES[id] == nil then
        self.FACTORIES[id] = factory
      else
        print("[__DISTILLER::define] module " .. tostring(id) .. " is already defined")
      end
    end,
    exec = function(self, id)
      local func = self.FACTORIES[id]
      assert(func, "missing factory method for id " .. tostring(id))
      func(__DISTILLER.require)
    end
  }
end

#{HR}
"""

# 要忽略包名
EXCLUDE_PACKAGE_NAMES = "cjson zlib pack socket lfs lsqlite3 Cocos2d Cocos2dConstants".split(" ")


fs = require "fs"
require "shelljs/global"
path = require "path"
_ = require "underscore"
child_process = require 'child_process'
debuglog = require('debug')('distill')

# 正则表达式匹配出 lua 代码中的 require 部分
RE_REQUIRE = /^.*require[\(\ ][\'"]([a-zA-Z0-9\.\_\/\-]+)[\'"]/mg

#Match prefix,                SPACE OR (

#Please, dont use variables on requires... Use module-loader instead
RE_REQUVAR = /^.*require\((.+)\)/mg
RE_LOADLIB = /^.*loadFromLib[\(\ ].+/mg
RE_REQFLIB = /^.*requireFromLib[\(\ ].+/mg

OUTPUT_PATH_MERGED_LUA = ""
OUTPUT_PATH_MINIFIED_LUA = ""

OUTPUT_PATH_MERGED_JIT = ""
OUTPUT_PATH_MINIFIED_JIT = ""

PATH_TO_LUA_SRC_DIET = path.resolve(__dirname, "../luasrcdiet/")
#console.log "[lua-distiller::PATH_TO_LUA_SRC_DIET] #{PATH_TO_LUA_SRC_DIET}"

PATH_TO_LUA_JIT = which "luajit"
#console.log "[lua-distiller::PATH_TO_LUA_JIT] #{PATH_TO_LUA_JIT}"

MODULES = {}

# 用于解决循环引用导致无限循环的问题
VISITED_PATH = {}
STACK = []

# 遇到错误时退出
quitWithError = (msg)->
  console.error "ERROR: #{msg}"
  process.exit 1

getMinExistent = (args...) ->
  ret = -1
  for num in args
    if(ret == -1 and num != -1)
      ret = num
    if(num != -1 and num < ret)
      ret = num
  return ret

#Check if the require is inside [[ ]]
  #Checkout that this will ignore inside ffi.cdef calls
getStringRanges = (str)->
  i = 0;
  len = str.length;

  strRanges = [];
  #While not terminated
  #Not handling block comment (--[[ )
  while(i != len - 1 and i != -1)
    #Handling of block comment
    tempInd = str.indexOf("--[[", i);
    tempInd2 = str.indexOf("ffi.cdef([[", i)
    ind = str.indexOf("[[", i);
    min = getMinExistent(tempInd, tempInd2, ind)
    if(ind != -1 && ind == min)
      # mPrint2 "Found a string block"
      i = ind;
      ind = str.indexOf("]]", i);
      if(ind != -1)
          ind+=2
      strRanges.push({start : i, end : ind});
      i = ind;
    else if(tempInd != -1 && tempInd == min)
      # mPrint3 "Found a comment block"
      i = str.indexOf("]]", tempInd+4) #This will jump comment
    else if(tempInd2 != -1 && tempInd2 == min)
      # mPrint3 "Found a ffi.cdef"
      i = str.indexOf("]]", tempInd2+11) #This will jump comment
    else if(min == -1)
      break
    # if tempInd != -1
    #   mPrint3 "Found a comment block"
    #   i = str.indexOf("]]", tempInd+4) #This will jump comment
    # else if tempInd2 != -1
    #   mPrint3 "Found a ffi.cdef"
    #   i = str.indexOf("]]", tempInd2+11) #This will jump comment
    # else
    #   ind = str.indexOf("[[", i);
    #   i = ind;
    #   if(i == -1)
    #     break
    #   ind = str.indexOf("]]", i);
    #   if(ind != -1)
    #       ind+=2
    #   strRanges.push({start : i, end : ind});
    #   i = ind;
  return strRanges;

isOnOpenStringDef = (strRanges, strPosition) ->
  if(strRanges.length == 0)
    return -1
  for i in [0..strRanges.length - 1]
    if strRanges[i]["start"] == -1 #When this is true, strRanges is 100% chance of having 1 length
      return -1
    else if strRanges[i]["end"] == -1#When this is true, 100% chance of being inside the string def and strRanges length == 1
      return i
    else if strPosition > strRanges[i]["start"] and strPosition < strRanges[i]["end"]#This is the only
      return i
  #Non handling cases:
    #No strRanges is not an array
    #strRanges length is 0(I believe it is impossible but..)
    #strPosition is a strange number(It will be -1 if you haven't used it on the matching replace)

  return -1

#Used only for |STRING| requires
deleteMetadata = (str) ->
  i = str.length - 1
  underCount = 0
  while(underCount != 4)
    if(str[i] == "+")
      underCount++
    i--
  return str.substring(0, i+1)#Compensation for the last i--

mPrint = (str) ->
  console.log("\x1b[36m%s\x1b[0m", str)

mPrint2 = (str) ->
  console.log("\x1b[1m\x1b[32m%s\x1b[0m", str)
mPrint3 = (str) ->
  console.log("\x1b[1m\x1b[28m%s\x1b[0m", str)

mPrintAlter = (str) ->
  if typeof(mPrintAlter.strong) == "undefined"
    mPrintAlter.strong = true
  if(mPrintAlter.strong)
    console.log("\x1b[1m\x1b[36m%s\x1b[0m", str)
  else
    console.log("\x1b[31m%s\x1b[0m", str)
  mPrintAlter.strong = !mPrintAlter.strong

mPrintAlter2 = (str) ->
  if typeof(mPrintAlter.strong) == "undefined"
    mPrintAlter.strong = true
  if(mPrintAlter.strong)
    console.log("\x1b[1m\x1b[36m%s\x1b[0m", str)
  else
    console.log("\x1b[36m%s\x1b[0m", str)
  mPrintAlter.strong = !mPrintAlter.strong


getStackPath = () ->
  if STACK.length > 0
    return STACK.toString().replace(/,/g, ".")+"."
  return ""

getPkgFromFilename = (filename) ->
  base = p.input
  base = base.substring(0, base.lastIndexOf("/"))

  return filename.substring(base.length + 1, filename.length - 4).replace(/\//g, ".") #+1 for removing "/" and -4 For removing ".lua"

scan = (filename, requiredBy) ->

  # 扫描文件中所有 require() 方法
  requiredBy or= p.input
  usingInit = false

  debuglog "scan: #{filename}, required by:#{requiredBy}"

  if(!fs.existsSync(filename))
    nFilename = filename.substring(0, filename.lastIndexOf(".lua"))+ "/init.lua"
    if(fs.existsSync(nFilename))
      filename = nFilename
      usingInit = true
    else
      quitWithError "missing file at #{filename}, required by:#{requiredBy}"

  code = fs.readFileSync filename, encoding : 'utf8'

  requires = []

  tstF = false


  if(usingInit)
    splt = filename.split("/")
    STACK.push(splt[splt.length - 2])
    mPrint3("Init.lua used, appending path '" + splt[splt.length-2] + "'")

  processedCode = code.replace RE_REQUIRE, (line, packageName, indexFrom, whole)->
    if line.indexOf("require(\"") != -1
      mPrint2("Not handling #{packageName}, it is defined as a static lib")
      return line

    if STACK.length > 0
      packageName = getStackPath() + packageName
      mPrint packageName
    ranges = getStringRanges(whole)
    rangeInd = isOnOpenStringDef(ranges, indexFrom)
    if rangeInd != -1
      mPrint2 "|STRING| definition for "+packageName + " on file #{filename}"
      packageName = packageName.replace(getStackPath(), "|STRING|")
      packageName = packageName + "+#{ranges[rangeInd]['start']}+#{ranges[rangeInd]['end']}+#{indexFrom}+#{getPkgFromFilename(filename)}"
      tstF = true
      requires.push packageName
      return line

    if packageName? and
    not VISITED_PATH["#{filename}->#{packageName}"] and       # 避免循环引用
    !~EXCLUDE_PACKAGE_NAMES.indexOf(packageName) and          # 避开的包
    (!~line.indexOf(COMMENT_MARK) and line.indexOf(COMMENT_MARK) < line.indexOf('require'))     # 忽略被注释掉的代码
      console.log "[lua-distiller] require #{packageName} in #{filename}"
      mPrint "  Pushing #{packageName}"
      requires.push packageName
      VISITED_PATH["#{filename}->#{packageName}"] = true
      #return line.replace("require", "__DEFINED.__get")
      return line
    else

      console.log "[lua-distiller] ignore #{packageName} in #{filename}"
      # 是被注释掉的 require
      return line

  #Should not have those variables, seriously, dont ever use variables with requires... or you should implement it there, i'm not doing it for ya again
  #Only using because REST-lib...
  processedCode = processedCode.replace RE_REQUVAR, (line, packageName, indexFrom, whole)->  
    if line.indexOf("require(path") != -1
        mPrintAlter "Require with variable found: #{line}"
        pkg = packageName.replace(/path\ \.\.\ \"(.+)\"/, (line, capture) -> return capture)
        mPrintAlter "Replacing it with #{STACK[STACK.length-1]}.#{pkg}"
        mPrint3 getStackPath()
        requires.push getStackPath() + pkg
        return line.replace("path .. \"", "\"#{STACK[STACK.length-1]}.")
      return line
  #Remove trash from luajit-request
  processedCode = processedCode.replace(/local\ path\ =\ \(...\)\:gsub\(.+/, "")

  for module in requires
    if(module.indexOf("|STRING|") != -1 )
      mPath = module.replace("|STRING|", "")
      #Need to replace the 4 plus with nothing
      mPath = deleteMetadata(mPath)
      pathToModuleFile = "#{mPath.replace(/\./g, '/')}.lua"
      pathToModuleFile = path.normalize(path.join(BASE_FILE_PATH, pathToModuleFile))
      # run recesively
      MODULES[module] = scan(pathToModuleFile, filename)
    else
      #continue if ~EXCLUDE_PACKAGE_NAMES.indexOf(module)
      # 忽略已经被摘取的模块, 但要提高这个依赖模块的排名
      continue if MODULES[module]

      pathToModuleFile = "#{module.replace(/\./g, '/')}.lua"
      pathToModuleFile = path.normalize(path.join(BASE_FILE_PATH, pathToModuleFile))
      # run recesively
      MODULES[module] = scan(pathToModuleFile, filename)

  processedCode = processedCode.replace RE_LOADLIB, (line, packageName, indexFrom, whole) ->
  
    if line.indexOf("function ") == -1 and
    (line.indexOf(COMMENT_MARK) == -1 or line.indexOf(COMMENT_MARK) > line.indexOf('require'))
      # Replaces every syntax symbol for getting only the meat
      nLine = line.replace(/[\(\)\"\ ]/g, "")
      nLine = nLine.replace("loadFromLib", "")
      #Split string, 0 = New search place, 1... = Requires
      pRequires = nLine.split(",")
      basePath = pRequires[0]
      stackPath = getStackPath()
      for i in [1..pRequires.length - 1]
        toRequire= "#{stackPath}#{basePath}.#{pRequires[i]}"
        requires.push toRequire
      #Push into path stack
      STACK.push(basePath)
      for module in requires
        continue if MODULES[module]
        # console.log("Adding #{module}")
        pathToModuleFile = "#{module.replace(/\./g, '/')}.lua"
        pathToModuleFile = path.normalize(path.join(BASE_FILE_PATH, pathToModuleFile))
        MODULES[module] = scan(pathToModuleFile, filename)
      STACK.pop()
      # console.log(VISITED_PATH)
      # console.log("[OHGOD]This is Correct!")
    return line

  processedCode = processedCode.replace RE_REQFLIB, (line, packageName, indexFrom, whole) ->
    #Remove function definition (module-loader)
    if line.indexOf("function ") == -1 and
    (line.indexOf(COMMENT_MARK) == -1 or line.indexOf(COMMENT_MARK) > line.indexOf('require'))
      mPrint line
      #No equal line(For stripping only the useful data)
      nEqual = line
      nInd = nEqual.indexOf("=")
      if(nInd != -1)
        nEqual = nEqual.substring(nInd+1)
      #Remove syntax symbols
      nLine = nEqual.replace(/[\(\)\"\ ]/g, "")
      nLine = nLine.replace("requireFromLib", "")
      mPrint nLine
      #Split into [0]=Libpath, [1]=Lib
      pRequires = nLine.split(",")
      basePath = pRequires[0]
      #Generate path to require
      toRequire= "#{getStackPath()}#{basePath}.#{pRequires[1]}"
      requires.push toRequire
      console.log("REQUIRED A " + toRequire )
      mPrint STACK
      #Add path into the stack
      STACK.push(basePath)
      for module in requires
        continue if MODULES[module]
        console.log("Adding #{module}")
        pathToModuleFile = "#{module.replace(/\./g, '/')}.lua"
        pathToModuleFile = path.normalize(path.join(BASE_FILE_PATH, pathToModuleFile))
        MODULES[module] = scan(pathToModuleFile, filename)
      STACK.pop()
      # console.log(VISITED_PATH)
    return line
  if(usingInit)
    STACK.pop()
  return processedCode


##======= 以下为主体逻辑

## validate input parameters
quitWithError "missing main entrance lua file (-i), use -h for help." unless p.input?

# validate input path
p.input = path.resolve process.cwd(), (p.input || '')
quitWithError "bad main entrance file: #{p.input}, #{path.extname(p.input)}." unless fs.existsSync(p.input) and path.extname(p.input) is EXTNAME
BASE_FILE_PATH = path.dirname p.input

if p.excludes
  EXCLUDE_PACKAGE_NAMES = EXCLUDE_PACKAGE_NAMES.concat(p.excludes.split(",").map((item)->item.trim()))

# figure out output path
p.output = path.resolve(process.cwd(), p.output || '')

if path.extname(p.output)
  OUTPUT_PATH_MERGED_LUA = path.resolve process.cwd(), p.output
  OUTPUT_PATH_MINIFIED_LUA = path.resolve(process.cwd(), "#{p.output}.min.lua")
else
  outputBasename = path.basename(p.output ||  p.input, '.lua')
  OUTPUT_PATH_MERGED_LUA = path.join p.output, "#{outputBasename}.merged.lua"
  OUTPUT_PATH_MINIFIED_LUA = path.join p.output, "#{outputBasename}.min.lua"

OUTPUT_PATH_MERGED_JIT = "#{OUTPUT_PATH_MERGED_LUA}jit"
OUTPUT_PATH_MINIFIED_JIT = "#{OUTPUT_PATH_MINIFIED_LUA}jit"

mkdir('-p', path.dirname(OUTPUT_PATH_MERGED_LUA))

## describe the job
console.log "lua-distiller v#{pkg.version}"
console.log "merge from #{path.relative(process.cwd(), p.input)} to #{path.relative(process.cwd(),OUTPUT_PATH_MERGED_LUA)}"
console.log "ignore package: #{EXCLUDE_PACKAGE_NAMES}"

## scan modules
console.log "scanning..."
#entranceName = path.basename(p.input, ".lua")
# NOTE: entranceName 使用随机内容，以避免在模块被再次引用的时候，由于包名在 require 时创建临时申明而产生冲突
entranceName = "#{path.basename(p.input)}_distilled"
MODULES[entranceName] = scan(p.input)

console.log "following modules have been scanned"
console.dir _.keys MODULES


console.log "scan complete, generate output to: #{OUTPUT_PATH_MERGED_LUA}"

result = "-- Generated by node-lua-distiller(version: #{pkg.version})  at #{new Date}"

# 换行
result += HR

# 加头
result += DISTILLER_HEAD

# 把依赖打包进去

#Please, used only for string requires
appendNext = false
appends = []

for moduleId, content of MODULES
  # 将 lua 实现代码加套 (function() end)() 的外壳然后注册到 __DEFINED 上去
  #Hipreme mod->
    #If it has the |STRING| in module, it should define the new module inside a '[['' string literal
    #This mod is for using together with Love2D Thread definitions, as the modules don't share the same code
  if moduleId.indexOf("|STRING|") != -1
    # appendNext = true
    appends.push({req : moduleId, content : content})
    mPrint3 "Appending #{moduleId}"
    continue
  else
    if(appends.length != 0)

      #Find the [[ definition for appending at it, append the distiller too
      #str definition index
      indexToAppend = content.indexOf("[[")
      #Current Comment Start, used for appending DISTILLER_HEAD
      currCommStart = -99
      nContent = ""
      addLength = 0
      indicesToRemove = []
      for i in [0..appends.length - 1]
        #0 = ID, 1 = Str Start, 2 = Str End, 3 = Place in Str, 4 = Target
        infos = appends[i].req.split("+")
        if(infos[4] != moduleId)
          continue
        indicesToRemove.push appends[i]
        _id = infos[0].replace("|STRING|", "")
        mPrintAlter "Appending #{appends[i]["req"]} at the module named '#{moduleId}'"

        commentStart = Number.parseInt(infos[1])
        commentEnd = Number.parseInt(infos[2])
        reqIndex = Number.parseInt(infos[3])
        console.log commentStart, commentEnd, reqIndex
        if(commentStart != currCommStart)
          currCommStart = commentStart
          #Copy until [[ + HEADER + Copy starting after comment start, total length added = 1 + DISTILLER_HEAD.length
          content = content.substring(0, commentStart + 2) + "\n#{DISTILLER_HEAD}" + content.substring(commentStart+3)#With that, HEAD was added
          addLength = DISTILLER_HEAD.length + 1 #If found new comment start, restarts the total to add length
        #Start place doesn't change
        reqIndex+= addLength
        commentEnd+= addLength
        #For later using to addLength
        toCopy = """
        __DISTILLER:define("#{_id}, function(require))
        #{MODULES[_id]}
        end)

        #{HR}
        """
        addLength+= toCopy.length
        #Copy until before require, add content definition
        content = content.substring(0, reqIndex-1) + toCopy + content.substring(reqIndex)
      #Remove deadobjects from appends
      for obj in indicesToRemove
        _ind = appends.indexOf(obj)
        if(_ind != -1)
          appends.splice(_ind, 1)
        currCommStart = -99

    result += """
  __DISTILLER:define("#{moduleId}", function(require)
  #{content}
  end)

  #{HR}
  """

# 加入口代码块
result += """
__DISTILLER:exec("#{entranceName}")
"""
# 输出

if p.nostring
  mPrint "No-String by Hipreme selected"
  result = result.replace /([\'\"])(.*?)\1/g, (line, replChar, group) ->
    ret = "\""
    for c in group
      ret+= "\\#{c.charCodeAt(0)}"
    ret+="\""
    # mPrintAlter("New = #{ret}")
    return ret


isInsideBlock = (ranges, ind) ->
  return isOnOpenStringDef(ranges, ind) != -1

randWord = (quant) ->
  letters = 25
  mWord = ""
  isCapital = false
  capStart = 65
  nCapStart = 97
  for i in [1..quant]
    isCapital = Math.random() >= 0.5
    if isCapital
      start = capStart
    else
      start = nCapStart
    mWord+= String.fromCharCode(start + Math.round(letters * Math.random()))
  return mWord
  
if p.scrabble
  mPrint2 "String-Scrabble by Hipreme Selected"
  count = 0
  tab = {}
  objs = {}
  ranges = getStringRanges(result)

  #Love namespace is reserved, dont add it to the function change pallete
  result = result.replace /.*?function\ ([^(]+)/mg, (line, funcName, ind) ->
    if funcName.indexOf("love.") != -1
      return line
    else if line.indexOf(COMMENT_MARK) != -1 and line.indexOf(COMMENT_MARK) < line.indexOf("function ")
      return line
    else if isInsideBlock(ranges, ind)
      console.log("#{line} is inside block")
      return line
    #If came from a object, store it in object list and its functions defined  
    if(funcName.indexOf(".") != -1 or funcName.indexOf(":") != -1)
      obj = null
      func = null
      if(funcName.indexOf(".") != -1)
        obj = funcName.split(".")[0]
        func = "."+funcName.split(".")[1]
        tab[funcName] = obj+"._HP"+count
      else 
        obj = funcName.split(":")[0]
        func = ":"+funcName.split(":")[1]
        tab[funcName] = obj+":_HP"+count
      if(!objs[obj])
        objs[obj] = {} #Table for accessing functions 
      objs[obj][func] = tab[funcName]
      count++ 
      return line
    else
      tab[funcName] = "_HP"+count
    count++ 
    mPrintAlter2 "#{funcName} -> #{tab[funcName]}"
    if(funcName.indexOf("local function ") != -1)
      return "local function #{tab[funcName]}"
    else
      return "function #{tab[funcName]}"
  # Replace all globals and local function whose is not a member
  for func of tab
    fName = tab[func]
    #For global and local functions(no member function included)
    if(fName.indexOf(".") == -1 and fName.indexOf(":") == -1)
      #           Dont matach if it has . or :, match when having function( or match if it has = with or without space and ends with ( or ;
      result = result.replace new RegExp("[^\\.\\:]#{func}\\(|\\=\\s?#{func}[\\;|\\(]", "mg"), (line, ind) ->
        if(isInsideBlock(ranges, ind))
          # mPrint2 "Mantaining:#{func}: it is inside block"
          return line
        else
          # mPrint3 "Replace:#{func} -> #{fName}"
        return line.replace(func, fName)
  #Replace every global member function

  globalObjs = []
  for obj of objs
    ind = result.indexOf("#{obj} = {}")
    if ind != -1
      globalObjs.push obj
  
  globCount = 0
  for obj in globalObjs
    nObj = randWord(Math.round(Math.random()*50 + 10))
    mPrint2 "Modifying #{obj} functions "
    for funcs of objs[obj]
      if(objs[obj][funcs].indexOf(":") == -1)
        nFunc = randWord(Math.round(Math.random()*50 + 10))

        result = result.replace new RegExp("#{obj}#{funcs}", "mg"), (funcMatched) ->
          return nFunc
        mPrint3  obj+funcs + " = " + nFunc


  #Protected keywords (Defined still as string, but could use it as a list) + (K|k)ey)
  words = {}
  result = result.replace /(game|ad|secret)key/mgi, (match) ->
    #Check if it has a object containing it(either as function or property (: or . ))
    if !words[match]
      #Generate a key for replacing everywhere, min 10 letters, max 60, is next to impossible for having a duplicate
      k = Math.round(Math.random()*50 + 10)
      words[match] = randWord(k)
      mPrintAlter2 "New key: #{match} -> #{words[match]}" 
    isFunc = match.split(":").length > 1
    isProp = match.split(".").length > 1
    if(isFunc)
      return match.split(":")[0]+":"+words[match]
    else if(isProp)
      return match.split(".")[0]+"."+words[match]
    else
      return words[match]


fs.writeFileSync OUTPUT_PATH_MERGED_LUA, result

if p.minify
  console.log "minify merged lua file to: #{OUTPUT_PATH_MINIFIED_LUA}"
  exec "cd #{PATH_TO_LUA_SRC_DIET} && ./LuaSrcDiet.lua #{OUTPUT_PATH_MERGED_LUA} -o #{OUTPUT_PATH_MINIFIED_LUA} "


if p.luajitify
  console.log "luajit compile merged lua file to #{OUTPUT_PATH_MERGED_JIT}"
  exec "#{PATH_TO_LUA_JIT} -b #{OUTPUT_PATH_MERGED_LUA} #{OUTPUT_PATH_MERGED_JIT}"

if p.luajitify and p.minify
  console.log "luajit compile minified merged lua file to #{OUTPUT_PATH_MINIFIED_JIT}"
  exec "#{PATH_TO_LUA_JIT} -b #{OUTPUT_PATH_MINIFIED_LUA} #{OUTPUT_PATH_MINIFIED_JIT}"

