local record App
   name: string
   version: integer
end

local app: App = { name = "tlbc", version = 1 }
print("hello from", app.name, app.version)
