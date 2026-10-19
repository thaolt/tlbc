local record Request
   url: string
   sink: any
end
local record http
   request: function(Request): any, integer, any, any
end
return http
