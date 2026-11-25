local Transport = {}

function Transport.check(impl)
  local missing = {}
  if type(impl.send) ~= "function" then
    missing[#missing + 1] = "send"
  end
  if type(impl.drain) ~= "function" then
    missing[#missing + 1] = "drain"
  end
  return missing
end

return Transport
