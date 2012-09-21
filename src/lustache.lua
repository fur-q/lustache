-- lustache: Lua mustache template parsing.
-- Copyright 2012 Olivine Labs, LLC <projects@olivinelabs.com>
-- MIT Licensed.

-- TODO: kill dangerous unicode https://github.com/janl/mustache.js/blob/master/mustache.js#L66

local Scanner  = require "lustache.scanner"
local Context  = require "lustache.context"

local error, ipairs, loadstring, pairs, setmetatable, tostring, type = 
      error, ipairs, loadstring, pairs, setmetatable, tostring, type 
local math_floor, math_max, string_gsub, string_gmatch, table_concat, table_remove =
      math.floor, math.max, string.gsub, string.gmatch, table.concat, table.remove

local patterns = {
  white = "%s*",
  space = "%s+",
  nonSpace = "%S",
  eq = "%s*=",
  curly = "%s*}",
  tag = "[#\\^/>{&=!]"
}

local html_escape_characters = {
  ["&"] = "&amp;",
  ["<"] = "&lt;",
  [">"] = "&gt;",
  ['"'] = "&quot;",
  ["'"] = "&#39;",
  ["/"] = "&#x2F"
}

local function is_array(array)
  local max, n = 0, 0
  for k, _ in pairs(array) do
    if not (type(k) == "number" and k > 0 and math_floor(k) == k) then
      return false 
    end
    max = math_max(max, k)
    n = n + 1
  end
  return n == max
end

-- Low-level function that compiles the given `tokens` into a
-- function that accepts two arguments: a Context and a
-- Renderer.

local function compile_tokens(tokens)
  local subs = {}

  local function subrender(i, tokens)
    if not subs[i] then
      local fn = compile_tokens(tokens)
      subs[i] = function(ctx, rnd) return fn(ctx, rnd) end
    end
    return subs[i]
  end

  local function render(ctx, rnd)
    local buf = {}
    local token, section
    for i, token in ipairs(tokens) do
      local t = token.type
      buf[#buf+1] = 
        t == "#" and rnd:_section(
          token.value, ctx, subrender(i, token.tokens)
        ) or
        t == "^" and rnd:_inverted(
          token.value, ctx, subrender(i, token.tokens)
        ) or
        t == ">" and rnd:_partial(token.value, ctx) or
        (t == "{" or t == "&") and rnd:_name(token.value, ctx, false) or
        t == "name" and rnd:_name(token.value, ctx, true) or
        t == "text" and token.value or ""
    end
    return table_concat(buf)
  end
  return render
end

local function escape_tags(tags)
  return {
    string_gsub(tags[1], "%%", "%%%%").."%s*",
    "%s*"..string_gsub(tags[2], "%%", "%%%%"),
  }
end

local function nest_tokens(tokens)
  local tree = {}
  local collector = tree 
  local sections = {}
  local token, section

  for i,token in ipairs(tokens) do
    if token.type == "#" or token.type == "^" then
      token.tokens = {}
      sections[#sections+1] = token
      collector[#collector+1] = token
      collector = token.tokens
    elseif token.type == "/" then
      if #sections == 0 then
        error("Unopened section: "..token.value)
      end

      -- Make sure there are no open sections when we're done
      section = table_remove(sections, #sections)

      if not section.value == token.value then
        error("Unclosed section: "..section.value)
      end

      if #sections > 0 then
        collector = sections[#sections].tokens
      else
        collector = tree
      end
    else
      collector[#collector+1] = token
    end
  end

  section = table_remove(sections, #sections)

  if section then
    error("Unclosed section: "..section.value)
  end

  return tree
end

local function make_context(view)
  if not view then return view end
  return view.magic == "1235123123" and view or Context:new(view)
end

local lustache = {
  name          = "lustache",
  version       = "1.1-1",
  cache         = {},
  partial_cache = {},
  tags          = {"{{", "}}"}
}

function lustache:clear_cache()
  self.cache = {}
  self.partial_cache = {}
end

function lustache:compile(tokens, tags)
  tags = tags or self.tags
  if type(tokens) == "string" then
    tokens = self:parse(tokens, tags)
  end

  local fn = compile_tokens(tokens)

  return function(view)
    return fn(make_context(view), self)
  end
end

function lustache:compile_partial(name, tokens, tags)
  tags = tags or self.tags
  self.partial_cache[name] = self:compile(tokens, tags)
  return self.partial_cache[name]
end

function lustache:render(template, view, partials)
  if partials then
    for name, body in pairs(partials) do
      self:compile_partial(name, body)
    end
  end

  if not template then
    return ""
  end

  local fn = self.cache[template]

  if not fn then
    fn = self:compile(template, self.tags)
    self.cache[template] = fn
  end

  return fn(view)
end

function lustache:_section(name, context, callback)
  local value = context:lookup(name)

  if type(value) == "table" then
    if is_array(value) then
      local buffer = {}
      for i,v in ipairs(value) do
        buffer[#buffer+1] = callback(context:push(v), self)
      end
      return table_concat(buffer)
    end
    return callback(context:push(value), self)
  elseif type(value) == "function" then
    return value(
      self,
      callback(context, self),
      function(template) return self:render(template, context) end
    ) or ""
  end
  return value and callback(context, self) or ""
end

function lustache:_inverted(name, context, callback)
  local value = context:lookup(name)

  -- From the spec: inverted sections may render text once based on the
  -- inverse value of the key. That is, they will be rendered if the key
  -- doesn't exist, is false, or is an empty list.

  return (value == nil or value == false or (is_array(value) and #value == 0)) and
    callback(context, self) or 
    ""
end

function lustache:_partial(name, context)
  local fn = self.partial_cache[name]
  return fn and fn(context, self) or ""
end

function lustache:_name(name, context, escape)
  local value = context:lookup(name)

  if type(value) == "function" then
    value = value(context.view)
  end

  local str = value == nil and "" or value
  str = tostring(str)

  if escape then
    return string_gsub(str, '[&<>"\'/]', function(s) return html_escape_characters[s] end)
  end

  return str
end

-- Breaks up the given `template` string into a tree of token objects. If
-- `tags` is given here it must be an array with two string values: the
-- opening and closing tags used in the template (e.g. ["<%", "%>"]). Of
-- course, the default is to use mustaches (i.e. Mustache.tags).
function lustache:parse(template, tags)
  tags = tags or self.tags
  local tag_patterns = escape_tags(tags)
  local scanner = Scanner:new(template)
  local tokens = {} -- token buffer

  local type, value, chr

  while not scanner:eos() do
    value = scanner:scan_until(tag_patterns[1])

    if value then
      tokens[#tokens+1] = { type = "text", value = value }
    end

    if not scanner:scan(tag_patterns[1]) then
      break
    end

    type = scanner:scan(patterns.tag) or "name"

    scanner:scan(patterns.white)

    if type == "=" then
      value = scanner:scan_until(patterns.eq)
      scanner:scan(patterns.eq)
      scanner:scan_until(tag_patterns[2])
    elseif type == "{" then
      local close_pattern = "%s*}"..tags[2]
      value = scanner:scan_until(close_pattern)
      scanner:scan(patterns.curly)
      scanner:scan_until(tag_patterns[2])
    else
      value = scanner:scan_until(tag_patterns[2])
    end

    if not scanner:scan(tag_patterns[2]) then
      error("Unclosed tag at " .. scanner.pos)
    end

    tokens[#tokens+1] = { type = type, value = value }

    if type == "=" then
      tags = {}
      for t in string_gmatch(value, "%S+") do tags[#tags+1] = t end
      tag_patterns = escape_tags(tags)
    end
  end

  return nest_tokens(tokens)
end

return lustache