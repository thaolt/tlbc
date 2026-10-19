-- External assets are plain files, read at runtime — nothing embedded.
-- Paths resolve against the process cwd; APP_DATA_DIR overrides the
-- lookup dir for deployed layouts (e.g. APP_DATA_DIR=/opt/app/share).
local data_dir = os.getenv("APP_DATA_DIR") or "data"
local asset = data_dir .. "/greeting.txt"

local f = io.open(asset, "r")
if f then
   local fh = f as FILE
   io.write("loaded from ", asset, ":\n", fh:read("*a"))
   fh:close()
else
   io.stderr:write("cannot open asset " .. asset .. "\n")
   os.exit(1)
end
