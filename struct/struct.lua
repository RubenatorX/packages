local ffi = require('ffi')
local bit = require('bit')
local string = require('string')
local os = require('os')
local math = require('math')
local table = require('table')

local error = error
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring
local type = type

local struct = {}
local tolua = {}
local toc = {}

local make_struct_cdef
do
    local table_concat = table.concat

    make_struct_cdef = function(arranged, size)
        local cdefs = {}
        local index = 0x00
        local offset = 0
        local bit_type
        local bit_type_size
        local unknown_count = 0
        local cdef_count = 0

        for i = 1, #arranged do
            local field = arranged[i]
            local ftype = field.type

            local is_bit = ftype.bits ~= nil

            if field.position then
                local diff = field.position - index
                if diff > 0 then
                    if bit_type then
                        cdef_count = cdef_count + 1
                        unknown_count = unknown_count + 1
                        cdefs[cdef_count] = bit_type .. ' __' .. tostring(unknown_count) .. ':' .. tostring(8 * bit_type_size - offset) .. ';'

                        diff = diff - bit_type_size
                        index = index + bit_type_size

                        offset = 0
                        bit_type = nil
                        bit_type_size = nil
                    end
                    if diff > 0 then
                        cdef_count = cdef_count + 1
                        unknown_count = unknown_count + 1
                        cdefs[cdef_count] = 'char __' .. tostring(unknown_count) .. '[' .. tostring(diff) .. '];'
                    end
                end
                index = index + diff
            end

            if is_bit then
                local bit_diff = field.offset - offset
                if bit_diff > 0 then
                    cdef_count = cdef_count + 1
                    unknown_count = unknown_count + 1
                    cdefs[cdef_count] = (bit_type or ftype.cdef) .. ' __' .. tostring(unknown_count) .. ':' .. tostring(bit_diff) .. ';'
                end
                offset = offset + bit_diff
            end

            cdef_count = cdef_count + 1
            if is_bit then
                cdefs[cdef_count] = ftype.cdef .. ' ' .. field.cname .. ':' .. tostring(ftype.bits) .. ';'
                offset = offset + ftype.bits
                if offset == 8 * ftype.size then
                    offset = 0
                    bit_type = nil
                    bit_type_size = nil
                    index = index + ftype.size
                else
                    bit_type = ftype.cdef
                    bit_type_size = ftype.size
                end
            else
                cdefs[cdef_count] = (ftype.name or ftype.cdef) .. ' ' .. field.cname .. ';'

                if ftype.size ~= '*' then
                    index = index + ftype.size
                end
            end
        end

        if bit_type then
            cdef_count = cdef_count + 1
            unknown_count = unknown_count + 1
            cdefs[cdef_count] = bit_type .. ' __' .. tostring(unknown_count) .. ':' .. tostring(8 * bit_type_size - offset) .. ';'

            index = index + bit_type_size

            offset = 0
            bit_type = nil
            bit_type_size = nil
        end

        if size and index < size then
            cdef_count = cdef_count + 1
            unknown_count = unknown_count + 1
            cdefs[cdef_count] = 'char __' .. tostring(unknown_count) .. '[' .. tostring(size - index) .. ']' .. ';'
        end

        return 'struct{' .. table_concat(cdefs) .. '}', size or index
    end
end

do
    local ffi_sizeof = ffi.sizeof

    local type_mt = {
        __index = function(base, count)
            if type(count) ~= 'number' and count ~= '*' then
                return nil
            end

            return struct.array(base, count)
        end,
    }

    struct.make_type = function(cdef, info)
        return setmetatable({
            cdef = cdef,
            size = info and info.size or ffi_sizeof(cdef),
        }, type_mt)
    end
end

struct.copy_type = function(base)
    local ftype = struct.make_type(base.cdef)

    for key, value in pairs(base) do
        ftype[key] = value
    end

    return ftype
end

local keywords = {
    ['auto'] = true,
    ['break'] = true,
    ['bool'] = true,
    ['case'] = true,
    ['char'] = true,
    ['complex'] = true,
    ['const'] = true,
    ['continue'] = true,
    ['default'] = true,
    ['do'] = true,
    ['double'] = true,
    ['else'] = true,
    ['enum'] = true,
    ['extern'] = true,
    ['float'] = true,
    ['for'] = true,
    ['goto'] = true,
    ['if'] = true,
    ['int'] = true,
    ['long'] = true,
    ['register'] = true,
    ['return'] = true,
    ['short'] = true,
    ['signed'] = true,
    ['sizeof'] = true,
    ['static'] = true,
    ['struct'] = true,
    ['switch'] = true,
    ['typedef'] = true,
    ['union'] = true,
    ['unsigned'] = true,
    ['void'] = true,
    ['volatile'] = true,
    ['while'] = true,
}

do
    local ffi_metatype = ffi.metatype
    local math_floor = math.floor
    local table_sort = table.sort

    local build_type = function(cdef, info)
        local ftype = struct.make_type(cdef, info)
        if info.signature then
            ftype.signature = info.signature
            ftype.offsets = info.offsets or {}
            ftype.static_offsets = info.static_offsets or {}
        end

        if info.size then
            ftype.size = info.size
        end

        ftype.info = info

        return ftype
    end

    local array_metatype = function(ftype)
        local base = ftype.base
        local count = ftype.count

        ffi_metatype(ftype.name, {
            __index = function(cdata, key)
                if key < 0 or key >= count then
                    error('Array index out of range (' .. tostring(key) .. '/' .. tostring(count - 1) .. ').')
                end

                local converter = base.converter
                if converter then
                    return tolua[converter](cdata.array[key], base)
                end

                return cdata.array[key]
            end,
            __newindex = function(cdata, key, value)
                if key < 0 or key >= count then
                    error('Array index out of range (' .. tostring(key) .. '/' .. tostring(count - 1) .. ').')
                end

                local converter = base.converter
                if converter then
                    toc[converter](cdata.array, key, value, base)
                    return
                end

                cdata.array[key] = value
            end,
            __pairs = function(cdata)
                return function(array, i)
                    i = i + 1
                    if i == count then
                        return nil, nil
                    end

                    return i, array[i]
                end, cdata.array, -1
            end,
            __ipairs = pairs,
            __len = function(_)
                return count
            end,
        })
    end

    local struct_metatype = function(ftype)
        local fields = ftype.fields

        ffi_metatype(ftype.name, {
            __index = function(cdata, key)
                local field = fields[key]
                if not field then
                    error('Unknown field \'' .. key .. '\'.')
                end

                if field.get then
                    return field.get(cdata)
                end

                if field.data then
                    return field.data
                end

                local data
                do
                    local child_ftype = field.type
                    local converter = child_ftype.converter
                    data = cdata[field.cname]
                    if converter then
                        data = tolua[converter](data, child_ftype)
                    end
                end

                local lookup = field.lookup
                if not lookup then
                    return data
                end

                if type(lookup) == 'table' then
                    return lookup[data]
                end

                return lookup(data, field)
            end,
            __newindex = function(cdata, key, value)
                local field = fields[key]
                if not field then
                    error('Unknown field \'' .. key .. '\'.')
                end

                if field.set then
                    field.set(cdata, value)
                    return
                end

                local child_ftype = field.type
                local converter = child_ftype.converter
                if converter then
                    toc[converter](cdata, field.cname, value, child_ftype)
                    return
                end

                cdata[field.cname] = value
            end,
            __pairs = function(cdata)
                return function(t, k)
                    local label = next(t, k)
                    return label, label and cdata[label]
                end, fields, nil
            end,
        })
    end

    struct.metatype = function(ftype)
        if ftype.count == nil then
            struct_metatype(ftype)
        else
            array_metatype(ftype)
        end
    end

    struct.array = function(info, base, count)
        info, base, count = count and info or {}, count and base or info, count or base

        local ftype = build_type(base.cdef, info)

        ftype.base = base
        ftype.count = count

        if count == '*' then
            return ftype
        end

        ftype.cdef = 'struct{' .. (base.name or base.cdef) .. ' array[' .. count .. '];}'
        ftype.size = base.size * count

        struct.name(ftype, info.name)
        struct.metatype(ftype)

        return ftype
    end

    struct.struct = function(info, fields)
        info, fields = fields and info or {}, fields or info

        local arranged = {}
        local arranged_index = 0
        local vla = {}
        for label, field in pairs(fields) do
            local position = field[2] and field[1]
            field.label = label
            field.position = position
            field.offset = field.offset or 0

            local ftype = field[2] or field[1]
            if ftype then
                local size = info.size
                if ftype.count == '*' and size then
                    local base = ftype.base
                    local fixed_ftype = struct.array(base, math_floor((size - position) / base.size))
                    ftype.base = nil
                    ftype.cdef = nil
                    ftype.count = nil
                    ftype.size = nil
                    for key, value in pairs(ftype) do
                        fixed_ftype[key] = value
                    end

                    ftype = fixed_ftype
                end

                field.type = ftype
                field.cname = (type(label) == 'number' or ftype.converter or field.lookup or keywords[label]) and '_' .. tostring(label) or label
                arranged_index = arranged_index + 1
                arranged[arranged_index] = field
            end
        end

        table_sort(arranged, function(field1, field2)
            if field1.position and field2.position then
                return field1.position < field2.position or field1.position == field2.position and field1.offset < field2.offset
            end

            if field1.position and not field2.position then
                return true
            end

            if not field1.position and field2.position then
                return false
            end

            return field1.label < field2.label
        end)

        local cdef, size = make_struct_cdef(arranged, info.size)
        info.size = size
        local ftype = build_type(cdef, info)

        struct.name(ftype, info.name)

        for key, value in pairs(vla) do
            ftype[key] = value
        end

        ftype.fields = fields
        ftype.arranged = arranged

        struct.metatype(ftype)

        return ftype
    end
end

do
    local ffi_cdef = ffi.cdef
    local string_sub = string.sub
    local string_gsub = string.gsub

    local declared_cache = {}
    local named_count = 0
    local package_identifier = string_gsub(package.name or '_script', '[^%w_]', '')

    local typedefs = {}

    struct.name = function(ftype, name)
        named_count = named_count + 1
        name = name or ftype.name
        if not name then
            name = '_gensym_' .. package_identifier .. '_' .. tostring(named_count)
        end

        ftype.name = name

        local declared = declared_cache[name]
        if declared then
            local tag = declared.tag
            ffi_cdef('typedef struct ' .. tag .. ' ' .. name .. ';')
            ffi_cdef('struct ' .. tag .. ' ' .. string_sub(ftype.cdef, 7) .. ';')
            typedefs[name] = tag

            for i = 1, #declared.ptrs do
                declared.ptrs[i].base = ftype
            end

            declared_cache[name] = nil
        else
            ffi_cdef('typedef ' .. ftype.cdef .. ' ' .. name .. ';')
            typedefs[name] = ftype.cdef
        end
    end

    struct.declare = function(name)
        local tag = name .. '_tag'
        ffi_cdef('struct ' .. tag .. ';')
        ffi_cdef('typedef struct ' .. tag .. ' ' .. name .. ';')
        typedefs[name] = tag

        declared_cache[name] = {
            tag = tag,
            ptrs = {},
        }
    end

    struct.ptr = function(base)
        local is_tag = type(base) == 'string'

        local base_def = not base and 'void' or is_tag and base or base.name or base.cdef
        local ftype = struct.make_type(base_def .. '*')

        ftype.ptr = true

        if is_tag then
            local ptrs = declared_cache[base].ptrs
            ptrs[#ptrs + 1] = ftype
        else
            ftype.base = base
        end

        return ftype
    end

    local typedefs_mt = {
        __index = typedefs,
        __newindex = error,
        __len = function(_)
            local count = 0
            for _ in pairs(typedefs) do
                count = count + 1
            end
            return count
        end,
        __pairs = function(_)
            return next, typedefs, nil
        end,
        __metatable = false,
    }

    struct.typedefs = setmetatable({}, typedefs_mt)
end

do
    local ffi_cast = ffi.cast

    struct.from_ptr = function(ftype, ptr)
        struct.name(ftype)
        return ffi_cast(ftype.name .. '*', ptr)[0]
    end
end

do
    local ffi_typeof = ffi.typeof

    local type_cache = {}

    struct.new = function(ftype, ...)
        local ctype = type_cache[ftype]
        if not ctype then
            ctype = ffi_typeof(ftype.name or ftype.cdef)
            type_cache[ftype] = ctype
        end

        return ctype(...)
    end
end

struct.tag = function(base, tag)
    local ftype = struct.copy_type(base)
    ftype.tag = tag
    return ftype
end

struct.uint8 = struct.make_type('uint8_t')
struct.uint16 = struct.make_type('uint16_t')
struct.uint32 = struct.make_type('uint32_t')
struct.uint64 = struct.make_type('uint64_t')
struct.int8 = struct.make_type('int8_t')
struct.int16 = struct.make_type('int16_t')
struct.int32 = struct.make_type('int32_t')
struct.int64 = struct.make_type('int64_t')
struct.float = struct.make_type('float')
struct.double = struct.make_type('double')
struct.bool = struct.make_type('bool')

do
    local ffi_string = ffi.string
    local ffi_copy = ffi.copy
    local string_sub = string.sub

    local string_cache = {}
    local data_cache = {}

    local make = function(size, tag, cache)
        size = size or '*'

        local ftype = cache[size]
        if not ftype then
            ftype = struct.array(struct.make_type('char'), size)
            ftype.converter = tag
            ftype.tag = tag

            if size ~= '*' then
                string_cache[size] = ftype
            end
        end

        return ftype
    end

    struct.string = function(size)
        return make(size, 'string', string_cache)
    end

    tolua.string = function(value, ftype)
        if ftype.size == '*' then
            return ffi_string(value)
        end

        for i = 0, ftype.size - 1 do
            if value[i] == 0 then
                return ffi_string(value, i)
            end
        end

        return ffi_string(value, ftype.size)
    end

    toc.string = function(instance, index, value, ftype)
        if ftype.size == '*' then
            ffi_copy(instance[index], value)
            return
        end

        ffi_copy(instance[index], string_sub(value, 1, ftype.size) .. '\x00')
    end

    struct.data = function(size)
        return make(size, 'data', data_cache)
    end

    tolua.data = function(value, ftype)
        return ffi_string(value, ftype.size)
    end

    toc.data = function(instance, index, value, ftype)
        ffi_copy(instance[index], value, ftype.size)
    end
end

struct.time = struct.tag(struct.uint32, 'time')
struct.time.converter = 'time'
do
    local now = os.time()
    local off = os.difftime(now, os.time(os.date('!*t', now)))

    tolua.time = function(value, ftype)
        return value + off
    end

    toc.time = function(instance, index, value, ftype)
        instance[index] = value - off
    end
end

do
    local band = bit.band
    local bor = bit.bor
    local rshift = bit.rshift
    local lshift = bit.lshift
    local math_floor = math.floor
    local ffi_cast = ffi.cast
    local ffi_string = ffi.string
    local ffi_typeof = ffi.typeof
    local string_byte = string.byte
    local string_find = string.find
    local string_sub = string.sub

    local ctype = ffi_typeof('char[?]')

    struct.packed_string = function(size, lookup_string)
        local ftype = struct.array(struct.make_type('char'), size)
        ftype.converter = 'packed_string'

        do
            ftype.fill_value = string_find(lookup_string, '\x00', 1, true) - 1
        end

        ftype.unpacked_size = math_floor(4 * size / 3)

        local lua_lookup = {}
        for i = 1, 0x40 do
            local char = string_sub(lookup_string, i, i)
            lua_lookup[i - 1] = char and string_byte(char) or 0
        end

        local c_lookup = {}
        for i, v in pairs(lua_lookup) do
            c_lookup[v] = i
        end

        ftype.lua_lookup = lua_lookup
        ftype.c_lookup = c_lookup

        return ftype
    end

    tolua.packed_string = function(value, ftype)
        local ptr = ffi_cast('uint8_t*', value)
        local lua_lookup = ftype.lua_lookup
        local res = ctype(ftype.unpacked_size)
        for i = 1, ftype.size / 3 do
            local unpacked = res + (i - 1) * 4
            local packed = ptr + (i - 1) * 3

            local v1 = packed[0]
            local v2 = packed[1]
            local v3 = packed[2]
            unpacked[0] = lua_lookup[rshift(v1, 2)];
            unpacked[1] = lua_lookup[bor(lshift(band(v1, 0x03), 4), rshift(band(v2, 0xF0), 4))];
            unpacked[2] = lua_lookup[bor(lshift(band(v2, 0x0F), 2), rshift(band(v3, 0xC0), 6))];
            unpacked[3] = lua_lookup[band(v3, 0x3F)];
        end

        return ffi_string(res)
    end

    toc.packed_string = function(instance, index, value, ftype)
        local ptr = ffi_cast('uint8_t*', instance[index])
        local c_lookup = ftype.c_lookup
        local fill_value = ftype.fill_value
        for i = 1, ftype.size / 3 do
            local packed = ptr + (i - 1) * 3
            local start = 1 + (i - 1) * 4

            local i1, i2, i3, i4 = string_byte(value, start, start + 3)
            local v1 = c_lookup[i1] or fill_value
            local v2 = c_lookup[i2] or fill_value
            local v3 = c_lookup[i3] or fill_value
            local v4 = c_lookup[i4] or fill_value
            packed[0] = bor(lshift(v1, 2), rshift(v2, 4))
            packed[1] = bor(lshift(v2, 4), rshift(v3, 2))
            packed[2] = bor(lshift(v3, 6), rshift(v4, 0))
        end
    end
end

struct.bit = function(base, bits)
    local ftype = struct.copy_type(base)

    ftype.bits = bits

    return ftype
end

struct.boolbit = function(base)
    local ftype = struct.bit(base, 1)

    ftype.converter = 'boolbit'

    return ftype
end

tolua.boolbit = function(value, ftype)
    return value == 1
end

toc.boolbit = function(instance, index, value, ftype)
    instance[index] = value and 1 or 0
end

do
    local math_floor = math.floor
    local band = bit.band
    local bor = bit.bor
    local bnot = bit.bnot
    local lshift = bit.lshift

    local bits_mt = {
        __index = function(t, k)
            local cdata = t._cdata
            local index = math_floor(k / 8)
            local current = cdata[index]
            local mask = lshift(1, k % 8)
            return band(current, mask) ~= 0
        end,
        __newindex = function(t, k, v)
            local cdata = t._cdata
            local index = math_floor(k / 8)
            local current = cdata[index]
            local mask = lshift(1, k % 8)
            cdata[index] = v and bor(current, mask) or band(current, bnot(mask))
        end,
        __pairs = function(t)
            return function(t, k)
                local key = k + 1
                if key >= t._bits then
                    return nil, nil
                end
                return key, t[key]
            end, t, -1
        end,
        __ipairs = pairs,
        __len = function(t)
            return t._bits
        end,
    }

    struct.bits = function(bytes)
        local ftype = struct.data(bytes)

        ftype.converter = 'bits'

        return ftype
    end

    tolua.bits = function(value, ftype)
        return setmetatable({
            _cdata = value,
            _bits = 8 * ftype.size
        }, bits_mt)
    end

    toc.bits = function(instance, index, value, ftype)
        local ptr = instance[index]
        for byte_index = 0, ftype.size - 1 do
            local byte = 0
            local current = 1
            for bit_index = 0, 7 do
                if value[8 * byte_index + bit_index] then
                    byte = byte + current
                end
                current = current * 2
            end

            ptr[byte_index] = byte
        end
    end
end

do
    local ffi_copy = ffi.copy
    local ffi_sizeof = ffi.sizeof
    local ffi_typeof = ffi.typeof

    struct.copy = function(cdata)
        local copy = ffi_typeof(cdata)()
        ffi_copy(copy, cdata, ffi_sizeof(cdata))
        return copy
    end
end

return struct

--[[
Copyright © 2018, Windower Dev Team
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the Windower Dev Team nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE WINDOWER DEV TEAM BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]
