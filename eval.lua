local require_path = (...):match("(.-)[^%.]+$")
local bit_conv = require(require_path.."bitconverter")
local bit = bit32

local function push(stack, value)
    stack[#stack+1] = value
end

local function pop(stack)
    local value = stack[#stack]
    stack[#stack] = nil
    return value
end

local function signed(N, i)
    if i > 2^(N-1) then
        return i - 2^N
    end
    return i
end

local function inv_signed(N, i)
    if i < 0 then
        return i + 2^N
    end
    return i
end

local function extend(M,N, i)
    return inv_signed(N, signed(M,i))
end

local function expand_type(t, module)
	if t == -1 then
        return {from = {}, to = {}}
	elseif type(t) == "string" then
		return {from = {}, to = {t}}
	else
		return module.types[t]
	end
end

local function find_mem_address(ins, stack, frame, N)
    local m = ins[2]
    local mem = frame.module.store.mems[1]
    local i = pop(stack)
    local ea = i + m[2]
    if ea + N/8 > #mem.data then
        error("trap")
    end
    return mem, ea
end

local function load_from(ins, stack, frame, N)
    local mem, ea = find_mem_address(ins, stack, frame, N)
    local bytes = {}
    for x=1,N/8 do
        bytes[x] = mem.data[ea+x]
    end
    return bytes
end

local function store_to(ins, stack, frame, bytes)
    local mem, ea = find_mem_address(ins, stack, frame, #bytes*8)
    for x=1,#bytes do
        mem.data[ea+x] = bytes[x]
    end
end



local eval_single_with, eval_instructions_with

local extra_instructions


local function invoke(addr, stack, frame, labels)
	local new_f = frame.module.store.funcs[addr+1]

	local arg_count = #new_f.type.from
	local args = {}
	for x=arg_count,1,-1 do
		args[x] = pop(stack) -- or args[arg_count-x+1] dont know which one
	end

    if new_f.hostcode then
        local results = {new_f.hostcode(table.unpack(args))}
        for x=1,#results do
            push(stack, results[x])
        end
        return
    end

	for x=1,#new_f.code.locals do
		if new_f.code.locals[x] == "i64" then
			args[x+arg_count] = {l = 0, h = 0}
		else
			args[x+arg_count] = 0
		end
	end
	
	local new_frame = {module = frame.module, locals = args, type=new_f.type}
	push(labels, new_f.type)
	local r, p = eval_instructions_with(new_f.code.body[1], stack, new_frame, labels)
	pop(labels)
    if r then
	    for x=1,#new_f.type[2] do
		    push(stack, p[x])
	    end
    end
end

local instructions = {
    -- CONTROL INSTRUCTIONS ---------------------
    [0x00] = function(ins, stack, frame) -- unreachable
        error("trap, unreachable")
    end,
    [0x01] = function(ins, stack, frame) -- noop
    end,
    [0x02] = function(ins, stack, frame, labels) -- block-- br skips
        local new_label = expand_type(ins[2], frame.module)
        push(labels, new_label)
        local stack_height = #stack
        local r, p = eval_instructions_with(ins[3], stack, frame, labels)
        pop(labels)
        if r == -1 then
            return -1, p
        end
        if r ~= nil then
            if r > 0 then
                return r - 1, p
            end
            if r > 0 then
                return r - 1, p
            end
            while #stack ~= stack_height do
                pop(stack)
            end
            for x=1,#new_label.to do
                push(stack, p[x])
            end
        end
    end,
    [0x03] = function(ins, stack, frame, labels) -- loop
        -- br loops again
        while true do
            local new_label = expand_type(ins[2], frame.module)
            push(labels, new_label)
            local stack_height = #stack
            local r, p = eval_instructions_with(ins[3], stack, frame, labels)
            pop(labels)
            if r == -1 then
                return -1, p
            end
            if r ~= nil then
                if r > 0 then
                    return r - 1, p
                end
                while #stack ~= stack_height do
                    pop(stack)
                end
                for x=1,#new_label.to do
                    push(stack, p[x])
                end
            else
                break
            end
        end
    end,
    [0x04] = function(ins, stack, frame, labels) --
        local new_label = expand_type(ins, frame.module)
        local c = pop(stack)
        local r, p
        push(labels, new_label)
        local stack_height = #stack
        if c ~= 0 then
            r, p = eval_instructions_with(ins[2], stack, frame, labels)
        else
            r, p = eval_instructions_with(ins[4] or {}, stack, frame, labels)
        end
        pop(labels)
        if r == -1 then
            return -1, p
        end
        if r ~= nil then
            if r > 0 then
                return r - 1, p
            end
            while #stack ~= stack_height do
                pop(stack)
            end
            for x=1,#new_label.to do
                push(stack, p[x])
            end
        end
    end,
    [0x0C] = function(ins, stack, frame, labels) -- br
        local label = labels[#labels-ins[2]]
        local pop_count = #label.to
        local p = {}
        for x=pop_count,1,-1 do
            p[x] = pop(stack)
        end
        return ins[2], p
    end,
    [0x0D] = function(ins, stack, frame, labels) -- br_if
        local c = pop(stack)
        if c ~= 0 then
            return eval_single_with({0x0C, ins[2]}, stack, frame, labels)
        else
            return
        end
    end,
    [0x0E] = function(ins, stack, frame, labels) -- br_table
        local i = pop(stack)
        if i+1 > #ins[2] then
            return eval_single_with({0x0C, ins[2][i+1]}, stack, frame, labels)
        else
            return eval_single_with({0x0C, ins[3]}, stack, frame, labels)
        end
    end,
    [0x0F] = function(ins, stack, frame, labels) -- return
        local pop_count = #frame.type.to
        local p = {}
        for x=pop_count,1,-1 do
            p[x] = pop(stack)
        end
        return -1, p
    end,
    [0x10] = function(ins, stack, frame, labels) -- call
        return invoke(ins[2], stack, frame, labels)
    end,
    [0x11] = function(ins, stack, frame, labels) -- call_indirect
        local tab = frame.module.store.tables[ins[2]+1]
        local ft_expect = frame.module.types[ins[3]+1]
        local i = pop(stack)
        if i >= #tab.elem then
            error("trap")
        end
        local r = tab.elem[i+1]
        if r == 0 then
            error("trap")
        end
        local ft_actual = frame.module.store.funcs[r+1].type
        if #ft_expect.from ~= #ft_actual.from then
            error("trap")
        end
        if #ft_expect.to ~= #ft_actual.to then
            error("trap")
        end
        for k,v in pairs(ft_actual.from) do
            if v ~= ft_expect[k] then
                error("trap")
            end
        end
        for k,v in pairs(ft_actual.to) do
            if v ~= ft_expect.to[k] then
                error("trap")
            end
        end
        return invoke(r, stack, frame, labels)
    end,
    -- REFERENCE INSTRUCTIONS -----------------------
    [0xD0] = function(ins, stack, frame) -- ref.null
        push(stack, 0)
    end,
    [0xD1] = function(ins, stack, frame) -- ref.is_null
        local val = pop(stack)
        if val == 0 then
            push(stack, 1)
        else
            push(stack, 0)
        end
    end,
    [0xD2] = function(ins, stack, frame) -- ref.func
        --[[
            from my current understanding:
            currently only one module can be loaded, so no lookup is required
        ]]
        push(stack, ins[2])
    end,
    -- PARAMETRIC INSTRUCTIONS -----------------------
    [0x1A] = function(ins, stack, frame) -- drop
        pop(stack)
    end,
    [0x1B] = function(ins, stack, frame) -- select
        local selector = pop(stack)
        local val2 = pop(stack)
        local val1 = pop(stack)
        if selector ~= 0 then
            push(stack, val1)
        else
            push(stack, val2)
        end
    end,
    -- VARIABLE INSTRUCTIONS -------------------------
    [0x20] = function(ins, stack, frame) -- local.get
        push(stack, frame.locals[ins[2]+1])
    end,
    [0x21] = function(ins, stack, frame) -- local.set
        frame.locals[ins[2]+1] = pop(stack)
    end,
    [0x22] = function(ins, stack, frame) -- local.tee
        frame.locals[ins[2]+1] = stack[#stack]
    end,
    [0x23] = function(ins, stack, frame) -- global.get
        push(stack, frame.module.store.globals[ins[2]+1].val)
    end,
    [0x24] = function(ins, stack, frame) -- global.set
        frame.module.store.globals[ins[2]+1].val = pop(stack)
    end,
    -- TABLE INSTRUCTIONS ----------------------------
    [0x25] = function(ins, stack, frame) -- table.get
        local tab = frame.module.store.tables[ins[2]]
        local i = pop(stack)
        if i >= #tab.elem then
            error("trap")
        end
        push(stack, tab.elem[i+1])
    end,
    [0x26] = function(ins, stack, frame) -- table.set
        local x = ins[2]
        local tab = frame.module.store.tables[x+1]
        local val = pop(stack)
        local i = pop(stack)
        if i >= #tab.elem then
            error("trap")
        end
        tab.elem[i+1] = val
    end,
    -- MEMORY INSTRUCTIONS ---------------------------
    [0x28] = function(ins, stack, frame) -- i32.load
        local bytes = load_from(ins, stack, frame, 32)
        push(stack, bit_conv.UInt8sToUInt32(table.unpack(bytes)))
    end,
    [0x29] = function(ins, stack, frame) -- i64.load
        local bytes = load_from(ins, stack, frame, 64)
        push(stack, {
            l=bit_conv.UInt8sToUInt32(table.unpack(bytes, 1, 4)),
            h=bit_conv.UInt8sToUInt32(table.unpack(bytes, 5, 8))
        })
    end,
    [0x2A] = function(ins, stack, frame) -- f32.load
        local bytes = load_from(ins, stack, frame, 32)
        push(stack, bit_conv.UInt32ToFloat(bit_conv.UInt8sToUInt32(table.unpack(bytes))))
    end,
    [0x2B] = function(ins, stack, frame) -- f64.load
        local bytes = load_from(ins, stack, frame, 64)
        push(stack, bit_conv.UInt32sToDouble(
            bit_conv.UInt8sToUInt32(table.unpack(bytes, 1, 4)),
            bit_conv.UInt8sToUInt32(table.unpack(bytes, 5, 8))
        ))
    end,
    [0x2C] = function(ins, stack, frame) -- i32.load8_s
        local bytes = load_from(ins, stack, frame, 8)
        push(stack, extend(8, 32, bytes[1]))
    end,
    [0x2D] = function(ins, stack, frame) -- i32.load8_u
        local bytes = load_from(ins, stack, frame, 8)
        push(stack, bytes[1])
    end,
    [0x2E] = function(ins, stack, frame) -- i32.load16_s
        local bytes = load_from(ins, stack, frame, 16)
        push(stack, extend(16,32, bit_conv.UInt8sToUInt16(table.unpack(bytes))))
    end,
    [0x2F] = function(ins, stack, frame) -- i32.load16_u
        local bytes = load_from(ins, stack, frame, 16)
        push(stack, bit_conv.UInt8sToUInt16(table.unpack(bytes)))
    end,
    [0x30] = function(ins, stack, frame) -- i64.load8_s
        local bytes = load_from(ins, stack, frame, 8)
        if bit.band(bytes[1], 0x80) ~= 0 then
            push(stack, {l=extend(8, 32, bytes[1]), h=0xFFFFFFFF})
        else
            push(stack, {l=bytes[1], h=0})
        end
    end,
    [0x31] = function(ins, stack, frame) -- i64.load8_u
        local bytes = load_from(ins, stack, frame, 8)
        push(stack, {l=bytes[1], h=0})
    end,
    [0x32] = function(ins, stack, frame) -- i64.load16_s
        local bytes = load_from(ins, stack, frame, 16)
        local raw_num = bit_conv.UInt8sToUInt16(table.unpack(bytes))
        if bit.band(raw_num, 0x8000) ~= 0 then
            push(stack, {l=extend(16, 32, raw_num), h=0xFFFFFFFF})
        else
            push(stack, {l=raw_num, h=0})
        end
    end,
    [0x33] = function(ins, stack, frame) -- i64.load16_u
        local bytes = load_from(ins, stack, frame, 16)
        push(stack, {l=bit_conv.UInt8sToUInt16(table.unpack(bytes)), h=0})
    end,
    [0x34] = function(ins, stack, frame) -- i64.load32_s
        local bytes = load_from(ins, stack, frame, 32)
        local raw_num = bit_conv.UInt8sToUInt32(table.unpack(bytes))
        if bit.band(raw_num, 0x80000000) ~= 0 then
            push(stack, {l = raw_num, h=0xFFFFFFFF})
        else
            push(stack, {l=raw_num, h=0})
        end
    end,
    [0x35] = function(ins, stack, frame) -- i64.load32_u
        local bytes = load_from(ins, stack, frame, 32)
        push(stack, {l=bit_conv.UInt8sToUInt32(table.unpack(bytes)), h=0})
    end,
    [0x36] = function(ins, stack, frame) -- i32.store
        local c = pop(stack)
        local bytes = {bit_conv.UInt32ToUInt8s(c)}
        store_to(ins, stack, frame, bytes)
    end,
    [0x37] = function(ins, stack, frame) -- i64.store
        local c = pop(stack)
        local u80, u81, u82, u83 = bit_conv.UInt32ToUInt8s(c.l)
        local u84, u85, u86, u87 = bit_conv.UInt32ToUInt8s(c.h)
        store_to(ins, stack, frame, {u80, u81, u82, u83, u84, u85, u86, u87})
    end,
    [0x38] = function(ins, stack, frame) -- f32.store
        local c = pop(stack)
        store_to(ins, stack, frame, {bit_conv.UInt32ToUInt8s(bit_conv.FloatToUInt32(c))})
    end,
    [0x39] = function(ins, stack, frame) -- f64.store
        local c = pop(stack)
        local l, h = bit_conv.DoubleToUInt32s(c)
        local u80, u81, u82, u83 = bit_conv.UInt32ToUInt8s(l)
        local u84, u85, u86, u87 = bit_conv.UInt32ToUInt8s(h)
        store_to(ins, stack, frame, {u80, u81, u82, u83, u84, u85, u86, u87})
    end,
    [0x3A] = function(ins, stack, frame) -- i32.store8
        local c = pop(stack)
        local u80, _, _, _ = bit_conv.UInt32ToUInt8s(c)
        store_to(ins, stack, frame, {u80})
    end,
    [0x3B] = function(ins, stack, frame) -- i32.store16
        local c = pop(stack)
        local u80, u81, _, _ = bit_conv.UInt32ToUInt8s(c)
        store_to(ins, stack, frame, {u80, u81})
    end,
    [0x3C] = function(ins, stack, frame) -- i64.store8
        local c = pop(stack)
        local u80, _, _, _ = bit_conv.UInt32ToUInt8s(c.l)
        store_to(ins, stack, frame, {u80})
    end,
    [0x3D] = function(ins, stack, frame) -- i64.store16
        local c = pop(stack)
        local u80, u81, _, _ = bit_conv.UInt32ToUInt8s(c.l)
        store_to(ins, stack, frame, {u80, u81})
    end,
    [0x3E] = function(ins, stack, frame) -- i64.store32
        local c = pop(stack)
        local bytes = {bit_conv.UInt32ToUInt8s(c.l)}
        store_to(ins, stack, frame, bytes)
    end,
    [0x3F] = function(ins, stack, frame) -- memory.size
        local m = ins[2]
        local mem = frame.module.store.mems[m]
        push(stack, #mem.data / 65536)
    end,
    [0x40] = function(ins, stack, frame) -- memory.grow
        local mem = frame.module.store.mems[ins[2]]
        local sz = #mem.data / 65536
        local n = pop(stack)
        if mem.type.max and mem.type.max < sz + n then
            push(stack, inv_signed(32, -1))
            return
        end
        local curr_index = sz * 65536
        for x=curr_index, curr_index+n*65536 do
            mem.data[x] = 0
        end
        push(stack, sz)
    end,
    -- NUMERICS -----------------------------
    [0x41] = function(ins, stack, frame) -- i32.const, i64.const, f32.const, f64.const
        push(stack, ins[2])
    end,
    [0x45] = function(ins, stack, frame) -- i32.eqz
        local n = pop(stack)
        if n == 0 then
            push(stack, 1)
        else
            push(stack, 0)
        end
    end,
    [0x46] = function(ins, stack, frame) -- i32.eq
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 == n2 then
            push(stack, 1)
        else
            push(stack, 0)
        end
    end,
    [0x47] = function(ins, stack, frame) -- i32.ne
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 == n2 then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x48] = function(ins, stack, frame) -- i32.lt_s NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if signed(32, n1) < signed(32, n2) then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x49] = function(ins, stack, frame) -- i32.lt_u NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 < n2 then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x4A] = function(ins, stack, frame) -- i32.gt_s NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if signed(32, n1) > signed(32, n2) then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x4B] = function(ins, stack, frame) -- i32.gt_u NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 > n2 then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x4C] = function(ins, stack, frame) -- i32.le_s NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if signed(32, n1) <= signed(32, n2) then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x4D] = function(ins, stack, frame) -- i32.le_u NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 <= n2 then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x4E] = function(ins, stack, frame) -- i32.ge_s NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if signed(32, n1) >= signed(32, n2) then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x4F] = function(ins, stack, frame) -- i32.ge_u NEW
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 >= n2 then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x5D] = function(ins, stack, frame) -- f32.lt
        local n2 = pop(stack)
        local n1 = pop(stack)
        if n1 < n2 then
            push(stack, 0)
        else
            push(stack, 1)
        end
    end,
    [0x6A] = function(ins, stack, frame) -- i32.add
        local n2 = pop(stack)
        local n1 = pop(stack)
        push(stack, bit.band(n1+n2, 0xFFFFFFFF))
    end,
    [0x6B] = function(ins, stack, frame) -- i32.sub
        local n2 = pop(stack)
        local n1 = pop(stack)
        push(stack, (n1-n2) % 0x100000000)
    end,
    [0x71] = function(ins, stack, frame) -- i32.and
        local n2 = pop(stack)
        local n1 = pop(stack)
        push(stack, bit.band(n1,n2))
    end,
    [0x72] = function(ins, stack, frame) -- i32.or
        local n2 = pop(stack)
        local n1 = pop(stack)
        push(stack, bit.bor(n1,n2))
    end,
    [0x76] = function(ins, stack, frame) -- i32.shr_u
        local n2 = pop(stack)
        local n1 = pop(stack)
        push(stack, bit.band(bit.blogic_rshift(n1,n2)))
    end,
    -- EXTRA INSTRUCTIONS ----------------------------
    [0xFC] = function(ins, stack, frame, labels)
        extra_instructions[ins[2]](ins, stack, frame, labels)
    end
}
instructions[0x1C] = instructions[0x1B]
instructions[0x42] = instructions[0x41]
instructions[0x43] = instructions[0x41]
instructions[0x44] = instructions[0x41]


for x=0x5B,0x60 do
    instructions[x+6] = instructions[x]
end
for x=0x8B,0x98 do
    instructions[x+14] = instructions[x]
end
for x=0xB2,0xB6 do
    instructions[x+5] = instructions[x]
end

extra_instructions = {
    [8] = function(ins, stack, frame) -- memory.init
        local y = ins[3]
        local x = ins[4]
        local mem = frame.module.store.mems[x+1]
        local da = frame.module.store.datas[y+1]
        local n = pop(stack)
        local s = pop(stack)
        local d = pop(stack)
        while true do
            if s + n > #da.data or d + n > #mem.data then
                error("trap")
            end
            if n == 0 then
                return
            end
            local b = da.data[s+1]
            push(stack, d)
            push(stack, b)
            eval_single_with({0x3A, {0,0}}, stack, frame) -- i32.store8
            d = d + 1
            s = s + 1
            n = n - 1
        end
    end,
    [9] = function(ins, stack, frame) -- data.drop
        local x = ins[3]
        frame.module.store.datas[x+1] = {data = {}}
    end,
    [10] = function(ins, stack, frame, labels) -- memory.copy
        local mem = stack.module.store.mems[1] -- cant tell which arg is to and which is from
        local n = pop(stack)
        local s = pop(stack)
        local d = pop(stack)
        if s + n > #mem.data or d + n > #mem.data then
            error("trap")
        end
        while n ~= 0 do
            if d <= s then
                push(stack, d)
                push(stack, s)
                eval_single_with({0x2D, {0,0}}, stack, frame, labels) -- i32.load8_u
                eval_single_with({0x3A, {0,0}}, stack, frame, labels) -- i32.store8
                d = d + 1
                s = s + 1
            else
                push(stack, d + n - 1)
                push(stack, s + n - 1)
                eval_single_with({0x2D, {0,0}}, stack, frame, labels) -- i32.load8_u
                eval_single_with({0x3A, {0,0}}, stack, frame, labels) -- i32.store8
            end
            n = n - 1
        end
    end,
    [11] = function(ins, stack, frame, labels) -- memory.fill
        local mem = stack.module.store.mems[ins[3]+1]
        local n = pop(stack)
        local val = pop(stack)
        local d = pop(stack)
        if d+n > #mem.data then
            error("trap")
        end
        while n ~= 0 do
            push(stack, d)
            push(stack, val)
            eval_single_with({0x38, {0,0}}, stack, frame, labels) -- i32.store8
            n = n - 1
            d = d + 1
        end
    end,
    [12] = function(ins, stack, frame, labels) -- table.init
        local y = ins[3]
        local x = ins[4]
        local tab = frame.module.store.tables[x+1]
        local elem = frame.module.store.elems[y+1]
        local n = pop(stack)
        local s = pop(stack)
        local d = pop(stack)
        while true do
            if s + n > #elem.elem or d + n > #tab.elem then
                error("trap")
            end
            if n == 0 then
                return
            end
            local val = elem.elem[s+1]
            push(stack, d)
            push(stack, val)
            eval_single_with({0x26, x}, stack, frame, labels) -- table.set
            d = d + 1
            s = s + 1
            n = n - 1
        end
    end,
    [13] = function(ins, stack, frame) -- elem.drop
        local x = ins[3]
        frame.module.store.elems[x+1] = {elem = {}, type=frame.module.store.elems[x+1].type}
    end,
    [14] = function(ins, stack, frame, labels) -- table.copy
        local tab_x = frame.module.store.tables[ins[3]+1]
        local tab_y = frame.module.store.tables[ins[4]+1]
        local n = pop(stack)
        local s = pop(stack)
        local d = pop(stack)
        if s + n > #tab_y.elem or d + n > #tab_x.elem then
            error("trap")
        end
        while n ~= 0 do
            if d <= s then
                push(stack, d)
                push(stack, s)
                eval_single_with({0x25, ins[4]}, stack, frame, labels)
                eval_single_with({0x26, ins[3]}, stack, frame, labels)
                d = d + 1
                s = s + 1
            else
                push(stack, d + n - 1)
                push(stack, s + n - 1)
                eval_single_with({0x25, ins[4]}, stack, frame, labels)
                eval_single_with({0x26, ins[3]}, stack, frame, labels)
            end
            n = n + 1
        end
    end,
    [15] = function(ins, stack, frame) -- table.grow
        local tab = frame.module.store.tables[ins[3] + 1]
        local n = pop(stack)
        local val = pop(stack)
        if tab.type.max and #tab.elem + n > tab.type.max then
            push(stack, -1)
        else
            local start_size = #tab.elem
            for x=1,n do
                tab.elem[start_size+x] = val
            end
            push(stack, start_size)
        end
    end,
    [16] = function(ins, stack, frame) -- table.size
        push(stack, #frame.module.store.tables[ins[3]+1].elem)
    end,
    [17] = function(ins, stack, frame, labels) -- table.fill
        local tab = frame.module.store.tables[ins[3]+1]
        local n = pop(stack)
        local val = pop(stack)
        local i = pop(stack)
        if n + i > #tab.elem then
            error("trap")
        end
        while n ~= 0 do
            push(stack, i)
            push(stack, val)
            eval_single_with({0x26, ins[3]}, stack, frame, labels)
            i = i + 1
            n = n - 1
        end
    end,
}

-- assumes that the expression is a constant expression that does not rely on having an available frame
local function simple_eval(expr)
    local stack = {}
    for _,ins in ipairs(expr[1]) do
        instructions[ins[1]](ins, stack, nil, nil)
    end
    return pop(stack)
end

local function simple_list_eval(exprs)
    local results = {}
    for i, expr in pairs(exprs) do
        results[i] = simple_eval(expr)
    end
    return results
end

eval_instructions_with = function(ins, stack, frame, labels)
    for _,ins in ipairs(ins) do
        local r,p = instructions[ins[1]](ins, stack, frame, labels)
        if r then return r,p end
    end
end

eval_single_with = function(ins, stack, frame, labels)
    return instructions[ins[1]](ins, stack, frame, labels)
end

local function fill_elems(module)
    local frame = {module = module, locals = {}}
    local stack = {}
    for idx,elem in pairs(module.elems) do
        if elem.mode == "active" then
            local n = #elem.init
            eval_instructions_with(elem.active_info.offset[1], stack, frame)
            push(stack, 0)
            push(stack, n)
            eval_single_with({0xFC, 12, idx-1, elem.active_info.table}, stack, frame)
            eval_single_with({0xFC, 13, idx-1}, stack, frame)
        end
    end
end

local function fill_datas(module)
    local frame = {module = module, locals = {}}
    local stack = {}
    for idx,data in pairs(module.datas) do
        if data.mode == "active" then
            local n = #data.init
            eval_instructions_with(data.active_info.offset[1], stack, frame)
            push(stack, 0)
            push(stack, n)
            eval_single_with({0xFC, 8, idx-1, data.active_info.memory}, stack, frame)
            eval_single_with({0xFC, 9, idx-1}, stack, frame)
        end
    end
end

local function call_start(module)
    if module.start and module.start.func then
        local start = module.start.func
        local stack = {}
        local frame = {module = module, locals = {}}
        eval_single_with({0x10, start.func}, stack, frame, {})

    end
end

local function call_function(module, funcidx, args)
    local frame = {module = module, locals = {}}
    eval_single_with({0x10, funcidx}, args, frame, {})
    return table.unpack(args)
end

local function make_memory_interface(module, memidx, interface_export)
    function interface_export.read8(address)
        local stack = {address}
        eval_single_with({0x2D, {0,0}}, stack, {module = module}, {})
        return stack[1]
    end
    function interface_export.read16(address)
        local stack = {address}
        eval_single_with({0x2F, {0,0}}, stack, {module = module}, {})
        return stack[1]
    end
    function interface_export.read32(address)
        local stack = {address}
        eval_single_with({0x28, {0,0}}, stack, {module = module}, {})
        return stack[1]
    end
    function interface_export.read64(address)
        local stack = {address}
        eval_single_with({0x29, {0,0}}, stack, {module = module}, {})
        return stack[1]
    end
    function interface_export.write8(address, value)
        local stack = {value, address}
        eval_single_with({0x3A, {0,0}}, stack, {module = module}, {})
    end
    function interface_export.write16(address, value)
        local stack = {value, address}
        eval_single_with({0x3B, {0,0}}, stack, {module = module}, {})
    end
    function interface_export.write32(address, value)
        local stack = {value, address}
        eval_single_with({0x36, {0,0}}, stack, {module = module}, {})
    end
    function interface_export.write64(address, value)
        local stack = {value, address}
        eval_single_with({0x37, {0,0}}, stack, {module = module}, {})
    end
    function interface_export.readf32(address)
        local stack = {address}
        eval_single_with({0x2A, {0,0}}, stack, {module = module}, {})
        return stack[1]
    end
    function interface_export.readf64(address)
        local stack = {address}
        eval_single_with({0x2B, {0,0}}, stack, {module = module}, {})
        return stack[1]
    end
    function interface_export.writef32(address, value)
        local stack = {value, address}
        eval_single_with({0x38, {0,0}}, stack, {module = module}, {})
    end
    function interface_export.writef64(address, value)
        local stack = {value, address}
        eval_single_with({0x39, {0,0}}, stack, {module = module}, {})
    end
end

return {
    simple = simple_eval,
    simple_list = simple_list_eval,
    fill_elems = fill_elems,
    fill_datas = fill_datas,
    call_start = call_start,
    call_function = call_function,
    make_memory_interface = make_memory_interface,
}