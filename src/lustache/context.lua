local string_find, string_gmatch, string_sub, tostring, type =
      string.find, string.gmatch, string.sub, tostring, type

local context = {}

function context:clear_cache()
  self.cache = {}
end

function context:push(view)
  return self:new(view, self)
end

function context:lookup(name)
  if self.cache[name] then return self.cache[name] end
  if name == "." then return self.view end

  local context, value = self, self.view

  local dot = string_find(name, "%.")
  if dot then
    for m in string_gmatch(name, "[^.]+") do
      value = value[m]
      if not value then break end
    end
  else
    while context do
      value = type(context.view) == "table" and context.view[name] or nil
      if value then break end
      context = context.parent
    end
  end

  self.cache[name] = value
  return value
end

function context:new(view, parent)
  local out = {
    view   = view,
    parent = parent,
    cache  = {},
    magic  = "1235123123", --ohgodwhy
  }
  return setmetatable(out, { __index = self })
end

return context
