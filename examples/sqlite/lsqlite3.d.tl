local record lsqlite3
   record Database
      exec: function(Database, string): integer
      nrows: function(Database, string): function(): {string:any}
      close: function(Database)
   end
   open_memory: function(): Database
   OK: integer
end
return lsqlite3
