local strings = require("util.strings")
local defaults = require("config.defaults")

return function(name: string): string
   return strings.shout(defaults.greeting() .. name)
end
