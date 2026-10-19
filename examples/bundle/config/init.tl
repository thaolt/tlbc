local defaults = require("config.defaults")

return {
   origin = function(): string
      return "config/defaults.tl (via config/init.tl): " .. defaults.greeting()
   end
}
