---@alias lexLua.Kind
---| '"comment"'
---| '"identifier"'
---| '"invalid"'
---| '"keyword"'
---| '"number"'
---| '"operator"'
---| '"string"'
---| '"whitespace"'

---@alias lexLua.MultilineKind
---| '"comment"'
---| '"string"'

---@alias lexLua.CommentKind
---| '"content"'
---| '"longbracket"'

---@alias lexLua.KeywordKind
---| '"flow"'
---| '"operator"'
---| '"value"'

---@alias lexLua.StringKind
---| '"content"'
---| '"escape"'
---| '"longbracket"'
---| '"quote"'

---@alias lexLua.SubKind lexLua.CommentKind|lexLua.KeywordKind|lexLua.StringKind

---@type table<lexLua.Kind, boolean|table<lexLua.SubKind, boolean>>
local tokens = {
  comment = {
    content = true;
    longbracket = true;
  };
  identifier = true;
  invalid = true;
  keyword = {
    flow = true;
    operator = true;
    value = true;
  };
  number = true;
  operator = true;
  string = {
    content = true;
    escape = true;
    longbracket = true;
    quote = true;
  };
  whitespace = true;
}

---@alias lexLua.Quote
---| '"\'"'
---| '"\\""'

---Allows keeping track of tokenization state across multiple lines.
---A whole line is the most atomic piece of code that can safely be tokenized.
---@class lexLua.State
---@field bracketLevel integer?
---@field multilineKind lexLua.MultilineKind?
---@field quote lexLua.Quote?
local State = {}

---@return lexLua.State
function State:copy()
  local state = State()
  state.bracketLevel = self.bracketLevel
  state.multilineKind = self.multilineKind
  state.quote = self.quote
  return state
end

---@return lexLua.State
function State.new()
  return setmetatable({}, State)
end

---Tokenizes a chunk of Lua code.
---@param code string
---@param state lexLua.State
---@return fun(): string, lexLua.Kind, lexLua.SubKind
local function tokenize(code, state)
  state = state or State.new()

  local keywords = {
    ["and"] = "operator";
    ["break"] = "flow";
    ["do"] = "flow";
    ["else"] = "flow";
    ["elseif"] = "flow";
    ["end"] = "flow";
    ["false"] = "value";
    ["for"] = "flow";
    ["function"] = "flow";
    ["goto"] = "flow";
    ["if"] = "flow";
    ["in"] = "flow";
    ["local"] = "value";
    ["nil"] = "value";
    ["not"] = "operator";
    ["or"] = "operator";
    ["repeat"] = "flow";
    ["return"] = "flow";
    ["then"] = "flow";
    ["true"] = "value";
    ["until"] = "flow";
    ["while"] = "flow";
  }

  local pos = 1

  ---@param token string
  ---@param kind lexLua.Kind
  ---@param subKind lexLua.SubKind?
  local function yield(token, kind, subKind)
    coroutine.yield(token, kind, subKind)
    pos = pos + #token
  end

  ---@param whitespace string
  local function processWhitespace(whitespace)
    yield(whitespace, "whitespace")
  end

  ---@param identifier string
  local function processIdentifier(identifier)
    local keyword = keywords[identifier]
    if keyword then
      yield(identifier, "keyword", keyword)
    else
      yield(identifier, "identifier")
    end
  end

  local function processNumber()
    local number =
    code:match("^0[xX]%x*%.%x+[pP][+%-]?%d+", pos) or
        code:match("^0[xX]%x+[pP][+%-]?%d+", pos) or
        code:match("^0[xX]%x*%.%x+", pos) or
        code:match("^0[xX]%x+", pos) or
        code:match("^%d*%.%d+[eE][+%-]?%d+", pos) or
        code:match("^%d+%.?[eE][+%-]?%d+", pos) or
        code:match("^%d*%.%d+", pos) or
        code:match("^%d+%.?", pos)
    if number then
      yield(number, "number")
    end
  end

  ---@param kind lexLua.Kind
  ---@param level integer
  local function continueMultiline(kind, level)
    local finalQuote = "]" .. ("="):rep(level) .. "]"
    local content = code:match("^(.-)" .. finalQuote, pos)
    if content then
      yield(content, kind, "content")
      yield(finalQuote, kind, "longbracket")
      state.kind = nil
      state.level = nil
    else
      yield(code:sub(pos), kind, "content")
      state.kind = kind
      state.level = level
    end
  end

  ---@param kind lexLua.Kind
  ---@param startQuote string
  local function processMultiline(kind, startQuote)
    yield(startQuote, kind, "longbracket")
    continueMultiline(kind, #startQuote - 2)
  end

  local function processComment()
    yield("--", "comment")
    local quote = code:match("^%[=*%[", pos)
    if quote then
      processMultiline("comment", quote)
    else
      local content = code:match("^[^\r\n]+", pos)
      if content then
        yield(content, "comment", "content")
      end
    end
  end

  ---@param quote string
  local function processMultilineString(quote)
    processMultiline("string", quote)
  end

  ---@param quote lexLua.Quote
  local function continueString(quote)
    local quotePattern = "^" .. quote
    local contentPattern = "^[^\\\r\n" .. quote .. "]+"
    while not code:find(quotePattern, pos) do
      local content = code:match(contentPattern, pos)
      if content then
        yield(content, "string", "content")
      else
        local escape = code:match("^\\%d%d?%d?", pos) or
            code:match("^\\u{%x+}", pos) or
            code:match("^\\\r\n", pos) or
            code:match("^\\.?", pos)
        if escape then
          yield(escape, "string", "escape")
          if #escape == 1 or escape == "\\\r" or escape == "\\\n" or escape == "\\\r\n" then
            state.kind = "string"
            state.quote = quote
            return
          end
        else
          return
        end
      end
    end
    yield(quote, "string", "quote")
  end

  ---@param quote lexLua.Quote
  local function processString(quote)
    yield(quote, "string", "quote")
    continueString(quote)
  end

  ---@param operator string
  local function processOperator(operator)
    yield(operator, "operator")
  end

  ---@param chars string
  local function processInvalid(chars)
    yield(chars, "invalid")
  end

  local processors = {
    { "^%s+", processWhitespace };

    { "^[%a_][%w_]*", processIdentifier };

    { "^%d", processNumber };

    { "^%-%-", processComment };

    { "^[\"']", processString };

    { "^%[=*%[", processMultilineString };

    { "^%.%.%.", processOperator };
    { "^%.%.", processOperator };
    { "^%.%d", processNumber };

    { "^::", processOperator };
    { "^~=", processOperator };
    { "^>>", processOperator };
    { "^>=", processOperator };
    { "^==", processOperator };
    { "^<=", processOperator };
    { "^<<", processOperator };
    { "^//", processOperator };

    { "^[%-,;:.()%[%]{}*/&#%^+<=>|~%%]", processOperator };

    { "^[^%w%s_\"'%-,;:.()%[%]{}*/&#%^+<=>|~%%]+", processInvalid };
    { "^.", processInvalid };
  }

  return coroutine.wrap(function()
    local len = #code
    while pos <= len do
      local kind = state.kind
      if kind then
        local level = state.level
        if level then
          assert(kind == "string" or kind == "comment")
          assert(type(level) == "number")
          continueMultiline(kind, level)
        else
          assert(kind == "string")
          ---@type lexLua.Quote
          local quote = state.quote
          state.kind = nil
          state.quote = nil
          continueString(quote)
        end
      else
        for i = 1, #processors do
          local match = code:match(processors[i][1], pos)
          if match then
            processors[i][2](match)
            break
          end
        end
      end
    end
  end)
end

return {
  tokenize = tokenize,
  tokens = tokens,
  State = State
}
