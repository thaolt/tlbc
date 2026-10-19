_G.tlbc_counter = (_G.tlbc_counter or 0) + 1
assert(_G.tlbc_counter == 1, "module initialized twice")
return { value = "counter-loaded-once" }
