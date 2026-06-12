local math, loadffi = ...
local sqrt, cos, sin, abs = math.sqrt, math.cos, math.sin, math.abs
local asin, atan2 = math.asin, math.atan2
local string_byte = string.byte
local vector2_ctor, vector3_ctor, vector4_ctor
local immutable_vector2_ctor, immutable_vector3_ctor, immutable_vector4_ctor
local box_ctor
local transform_move_ctor, transform_scale_ctor, transform_rotate_ctor
local transform_rotatex_ctor, transform_rotatey_ctor, transform_rotatez_ctor
local transform_identity_value

local function badarg(n, name)
  error('bad argument #'..n..' to '..name..' (number expected)', 3)
end

local function check_constructor(name, n, ...)
  if select('#', ...) ~= n then
    error(name..' constructor requires exactly '..n..' numeric arguments', 3)
  end
  for i = 1, n do
    if type(select(i, ...)) ~= 'number' then badarg(i, name) end
  end
end

local function build_geometry(ffi)
  if type(ffi) ~= 'table' or type(ffi.typeof) ~= 'function' or
     type(ffi.metatype) ~= 'function' or type(ffi.istype) ~= 'function' then
    error('math geometry requires a valid ffi module', 3)
  end

  local vector2_type = ffi.typeof('struct { float x, y; }')
  local vector3_type = ffi.typeof('struct { float x, y, z; }')
  local vector4_type = ffi.typeof('struct { float x, y, z, w; }')
  local immutable_vector2_type = ffi.typeof('struct { const float x, y; }')
  local immutable_vector3_type = ffi.typeof('struct { const float x, y, z; }')
  local immutable_vector4_type = ffi.typeof('struct { const float x, y, z, w; }')
  local transformm_type = ffi.typeof('struct { const float m00, m01, m02, m10, m11, m12, m20, m21, m22, m30, m31, m32; }')
  local transformq_type = ffi.typeof('struct { const float qx, qy, qz, qw; }')
  local box_type = ffi.typeof('struct { const $ center; const $ halfSize; const float qx, qy, qz, qw; }', immutable_vector3_type, immutable_vector3_type)
  local vector2, vector3, vector4
  local immutable_vector2, immutable_vector3, immutable_vector4
  local transformm, transformq
  local box
  local function is_mvec2(v) return ffi.istype(vector2_type, v) end
  local function is_mvec3(v) return ffi.istype(vector3_type, v) end
  local function is_mvec4(v) return ffi.istype(vector4_type, v) end
  local function is_ivec2(v) return ffi.istype(immutable_vector2_type, v) end
  local function is_ivec3(v) return ffi.istype(immutable_vector3_type, v) end
  local function is_ivec4(v) return ffi.istype(immutable_vector4_type, v) end
  local function is_transformm(v) return ffi.istype(transformm_type, v) end
  local function is_transformq(v) return ffi.istype(transformq_type, v) end
  local function is_box(v) return ffi.istype(box_type, v) end
  local function err_type(name, op)
    error(name..' expected for '..op, 3)
  end
  local function err_scalar(name, op)
    error(name..' can only be '..op..' by scalar', 3)
  end
  local function swizzle2_component(v, c)
    if c == 120 then return v.x end
    if c == 121 then return v.y end
    if c == 48 then return 0 end
    if c == 49 then return 1 end
  end

  local function swizzle3_component(v, c)
    if c == 120 then return v.x end
    if c == 121 then return v.y end
    if c == 122 then return v.z end
    if c == 48 then return 0 end
    if c == 49 then return 1 end
  end

  local function swizzle4_component(v, c)
    if c == 120 then return v.x end
    if c == 121 then return v.y end
    if c == 122 then return v.z end
    if c == 119 then return v.w end
    if c == 48 then return 0 end
    if c == 49 then return 1 end
  end

  local function decode_swizzle(v, key, component, immutable)
    local n = #key
    if n < 1 or n > 4 then return nil end
    local a = component(v, string_byte(key, 1))
    if a == nil then return nil end
    if n == 1 then return a end
    local b = component(v, string_byte(key, 2))
    if b == nil then return nil end
    if n == 2 then
      if immutable then return immutable_vector2(a, b) end
      return vector2(a, b)
    end
    local c = component(v, string_byte(key, 3))
    if c == nil then return nil end
    if n == 3 then
      if immutable then return immutable_vector3(a, b, c) end
      return vector3(a, b, c)
    end
    local d = component(v, string_byte(key, 4))
    if d == nil then return nil end
    if immutable then return immutable_vector4(a, b, c, d) end
    return vector4(a, b, c, d)
  end

  local function swizzle_index(Methods, component, immutable)
    return function(v, key)
      if type(key) ~= 'string' then return nil end
      local method = Methods[key]
      if method ~= nil then return method end
      return decode_swizzle(v, key, component, immutable)
    end
  end

  local function is_vec3(v) return is_mvec3(v) or is_ivec3(v) end

  local function quat_mul_components(ax, ay, az, aw, bx, by, bz, bw)
    return aw*bx + ax*bw + ay*bz - az*by,
           aw*by - ax*bz + ay*bw + az*bx,
           aw*bz + ax*by - ay*bx + az*bw,
           aw*bw - ax*bx - ay*by - az*bz
  end

  local function quat_apply_xyz(qx, qy, qz, qw, x, y, z)
    local tx = 2 * (qy*z - qz*y)
    local ty = 2 * (qz*x - qx*z)
    local tz = 2 * (qx*y - qy*x)
    return x + qw*tx + qy*tz - qz*ty,
           y + qw*ty + qz*tx - qx*tz,
           z + qw*tz + qx*ty - qy*tx
  end

  local function quat_from_axis_angle(angle, x, y, z)
    local len = sqrt(x*x + y*y + z*z)
    -- Match osg::Quat::makeRotate: tiny finite axes are identity, but NaN
    -- axes must propagate instead of being laundered into identity.
    if len < 0.0000001 then return transformq(0, 0, 0, 1) end
    local s = sin(angle * 0.5) / len
    return transformq(x*s, y*s, z*s, cos(angle * 0.5))
  end

  local function quat_mul(a, b)
    return transformq(quat_mul_components(a.qx, a.qy, a.qz, a.qw, b.qx, b.qy, b.qz, b.qw))
  end

  local function quat_inverse(q)
    local len2 = q.qx*q.qx + q.qy*q.qy + q.qz*q.qz + q.qw*q.qw
    if len2 > 0 then
      return transformq(-q.qx/len2, -q.qy/len2, -q.qz/len2, q.qw/len2)
    end
    return transformq(0, 0, 0, 1)
  end

  local function matrix_from_quat_components(qx, qy, qz, qw)
    local len2 = qx*qx + qy*qy + qz*qz + qw*qw
    if len2 <= 2.2250738585072014e-308 then
      return transformm(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    end
    local rlen2 = 2
    if len2 ~= 1 then rlen2 = 2 / len2 end
    local x2, y2, z2 = rlen2*qx, rlen2*qy, rlen2*qz
    local xx, yy, zz = qx*x2, qy*y2, qz*z2
    local xy, xz, yz = qx*y2, qx*z2, qy*z2
    local wx, wy, wz = qw*x2, qw*y2, qw*z2
    return transformm(
      1 - (yy + zz), xy + wz,      xz - wy,
      xy - wz,       1 - (xx + zz), yz + wx,
      xz + wy,       yz - wx,       1 - (xx + yy),
      0, 0, 0)
  end

  local function matrix_from_quat(q)
    return matrix_from_quat_components(q.qx, q.qy, q.qz, q.qw)
  end

  local function matrix_apply_vec(m, v)
    return vector3(
      v.x*m.m00 + v.y*m.m10 + v.z*m.m20 + m.m30,
      v.x*m.m01 + v.y*m.m11 + v.z*m.m21 + m.m31,
      v.x*m.m02 + v.y*m.m12 + v.z*m.m22 + m.m32)
  end

  local function matrix_mul(a, b)
    return transformm(
      a.m00*b.m00 + a.m01*b.m10 + a.m02*b.m20,
      a.m00*b.m01 + a.m01*b.m11 + a.m02*b.m21,
      a.m00*b.m02 + a.m01*b.m12 + a.m02*b.m22,
      a.m10*b.m00 + a.m11*b.m10 + a.m12*b.m20,
      a.m10*b.m01 + a.m11*b.m11 + a.m12*b.m21,
      a.m10*b.m02 + a.m11*b.m12 + a.m12*b.m22,
      a.m20*b.m00 + a.m21*b.m10 + a.m22*b.m20,
      a.m20*b.m01 + a.m21*b.m11 + a.m22*b.m21,
      a.m20*b.m02 + a.m21*b.m12 + a.m22*b.m22,
      a.m30*b.m00 + a.m31*b.m10 + a.m32*b.m20 + b.m30,
      a.m30*b.m01 + a.m31*b.m11 + a.m32*b.m21 + b.m31,
      a.m30*b.m02 + a.m31*b.m12 + a.m32*b.m22 + b.m32)
  end

  local function matrix_inverse(m)
    local a00, a01, a02 = m.m00, m.m01, m.m02
    local a10, a11, a12 = m.m10, m.m11, m.m12
    local a20, a21, a22 = m.m20, m.m21, m.m22
    local det = a00*(a11*a22 - a12*a21) - a01*(a10*a22 - a12*a20) + a02*(a10*a21 - a11*a20)
    local invdet = 1 / det
    local i00 =  (a11*a22 - a12*a21) * invdet
    local i01 =  (a02*a21 - a01*a22) * invdet
    local i02 =  (a01*a12 - a02*a11) * invdet
    local i10 =  (a12*a20 - a10*a22) * invdet
    local i11 =  (a00*a22 - a02*a20) * invdet
    local i12 =  (a02*a10 - a00*a12) * invdet
    local i20 =  (a10*a21 - a11*a20) * invdet
    local i21 =  (a01*a20 - a00*a21) * invdet
    local i22 =  (a00*a11 - a01*a10) * invdet
    return transformm(i00, i01, i02, i10, i11, i12, i20, i21, i22,
      -(m.m30*i00 + m.m31*i10 + m.m32*i20),
      -(m.m30*i01 + m.m31*i11 + m.m32*i21),
      -(m.m30*i02 + m.m31*i12 + m.m32*i22))
  end

  local function normalize_xyz(x, y, z)
    local len = sqrt(x*x + y*y + z*z)
    if len > 0 then
      local inv = 1 / len
      return x*inv, y*inv, z*inv, len
    end
    return x, y, z, len
  end

  local X, Y, Z, W = 1, 2, 3, 4
  local SQRTHALF = 0.7071067811865475244

  local qxtoz = { x = 0, y = SQRTHALF, z = 0, w = SQRTHALF }
  local qytoz = { x = SQRTHALF, y = 0, z = 0, w = SQRTHALF }
  local qppmm = { x = 0.5, y = 0.5, z = -0.5, w = -0.5 }
  local qpppp = { x = 0.5, y = 0.5, z = 0.5, w = 0.5 }
  local qmpmm = { x = -0.5, y = 0.5, z = -0.5, w = -0.5 }
  local qpppm = { x = 0.5, y = 0.5, z = 0.5, w = -0.5 }
  local q0001 = { x = 0, y = 0, z = 0, w = 1 }
  local q1000 = { x = 1, y = 0, z = 0, w = 0 }

  local function hmat_zero()
    return {
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
    }
  end

  local function hmat_identity()
    return {
      { 1, 0, 0, 0 },
      { 0, 1, 0, 0 },
      { 0, 0, 1, 0 },
      { 0, 0, 0, 1 },
    }
  end

  local function hmat_set_identity(m)
    for i = X, W do
      for j = X, W do
        m[i][j] = 0
      end
      m[i][i] = 1
    end
  end

  local function hmat_copy3(m)
    local r = hmat_zero()
    for i = X, Z do
      for j = X, Z do
        r[i][j] = m[i][j]
      end
    end
    return r
  end

  local function hmat_transpose3(m)
    local r = hmat_zero()
    for i = X, Z do
      for j = X, Z do
        r[i][j] = m[j][i]
      end
    end
    return r
  end

  local function hmat_pad(m)
    m[W][X], m[X][W] = 0, 0
    m[W][Y], m[Y][W] = 0, 0
    m[W][Z], m[Z][W] = 0, 0
    m[W][W] = 1
  end

  local function hmat_mult3(a, b)
    local r = hmat_zero()
    for i = X, Z do
      for j = X, Z do
        r[i][j] = a[i][X]*b[X][j] + a[i][Y]*b[Y][j] + a[i][Z]*b[Z][j]
      end
    end
    return r
  end

  local function vdot(ax, ay, az, bx, by, bz)
    return ax*bx + ay*by + az*bz
  end

  local function vcross(ax, ay, az, bx, by, bz)
    return ay*bz - az*by, az*bx - ax*bz, ax*by - ay*bx
  end

  local function adjoint_transpose(m)
    local r = hmat_zero()
    r[X][X], r[X][Y], r[X][Z] = vcross(m[Y][X], m[Y][Y], m[Y][Z], m[Z][X], m[Z][Y], m[Z][Z])
    r[Y][X], r[Y][Y], r[Y][Z] = vcross(m[Z][X], m[Z][Y], m[Z][Z], m[X][X], m[X][Y], m[X][Z])
    r[Z][X], r[Z][Y], r[Z][Z] = vcross(m[X][X], m[X][Y], m[X][Z], m[Y][X], m[Y][Y], m[Y][Z])
    return r
  end

  local function find_max_col(m)
    local max_value, col = 0, 0
    for i = X, Z do
      for j = X, Z do
        local value = abs(m[i][j])
        if value > max_value then
          max_value, col = value, j
        end
      end
    end
    return col
  end

  local function make_reflector(x, y, z)
    local s = sqrt(x*x + y*y + z*z)
    z = z + ((z < 0) and -s or s)
    s = sqrt(2 / (x*x + y*y + z*z))
    return x*s, y*s, z*s
  end

  local function reflect_cols(m, ux, uy, uz)
    for i = X, Z do
      local s = ux*m[X][i] + uy*m[Y][i] + uz*m[Z][i]
      m[X][i] = m[X][i] - ux*s
      m[Y][i] = m[Y][i] - uy*s
      m[Z][i] = m[Z][i] - uz*s
    end
  end

  local function reflect_rows(m, ux, uy, uz)
    for i = X, Z do
      local s = ux*m[i][X] + uy*m[i][Y] + uz*m[i][Z]
      m[i][X] = m[i][X] - ux*s
      m[i][Y] = m[i][Y] - uy*s
      m[i][Z] = m[i][Z] - uz*s
    end
  end

  local function do_rank1(m, q)
    hmat_set_identity(q)
    local col = find_max_col(m)
    if col == 0 then return end
    local v1x, v1y, v1z = make_reflector(m[X][col], m[Y][col], m[Z][col])
    reflect_cols(m, v1x, v1y, v1z)
    local v2x, v2y, v2z = make_reflector(m[Z][X], m[Z][Y], m[Z][Z])
    reflect_rows(m, v2x, v2y, v2z)
    if m[Z][Z] < 0 then q[Z][Z] = -1 end
    reflect_cols(q, v1x, v1y, v1z)
    reflect_rows(q, v2x, v2y, v2z)
  end

  local function do_rank2(m, madjt, q)
    local col = find_max_col(madjt)
    if col == 0 then
      do_rank1(m, q)
      return
    end
    local v1x, v1y, v1z = make_reflector(madjt[X][col], madjt[Y][col], madjt[Z][col])
    reflect_cols(m, v1x, v1y, v1z)
    local v2x, v2y, v2z = vcross(m[X][X], m[X][Y], m[X][Z], m[Y][X], m[Y][Y], m[Y][Z])
    v2x, v2y, v2z = make_reflector(v2x, v2y, v2z)
    reflect_rows(m, v2x, v2y, v2z)
    local w, x, y, z = m[X][X], m[X][Y], m[Y][X], m[Y][Y]
    local c, s, d
    if w*z > x*y then
      c, s = z + w, y - x
      d = sqrt(c*c + s*s)
      c, s = c/d, s/d
      q[X][X], q[Y][Y] = c, c
      q[X][Y], q[Y][X] = -s, s
    else
      c, s = z - w, y + x
      d = sqrt(c*c + s*s)
      c, s = c/d, s/d
      q[X][X], q[Y][Y] = -c, c
      q[X][Y], q[Y][X] = s, s
    end
    q[X][Z], q[Z][X], q[Y][Z], q[Z][Y], q[Z][Z] = 0, 0, 0, 0, 1
    reflect_cols(q, v1x, v1y, v1z)
    reflect_rows(q, v2x, v2y, v2z)
  end

  local function hmat_norm(m, transpose)
    local max_value = 0
    for i = X, Z do
      local sum
      if transpose then
        sum = abs(m[X][i]) + abs(m[Y][i]) + abs(m[Z][i])
      else
        sum = abs(m[i][X]) + abs(m[i][Y]) + abs(m[i][Z])
      end
      if max_value < sum then max_value = sum end
    end
    return max_value
  end

  local function quat_new(x, y, z, w)
    return { x = x, y = y, z = z, w = w }
  end

  local function quat_mul_decomp(a, b)
    return quat_new(
      a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
      a.w*b.y + a.y*b.w + a.z*b.x - a.x*b.z,
      a.w*b.z + a.z*b.w + a.x*b.y - a.y*b.x,
      a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z)
  end

  local function quat_conj(q)
    return quat_new(-q.x, -q.y, -q.z, q.w)
  end

  local function quat_scale(q, s)
    return quat_new(q.x*s, q.y*s, q.z*s, q.w*s)
  end

  local function quat_from_hmat(m)
    local q = quat_new(0, 0, 0, 1)
    local tr = m[X][X] + m[Y][Y] + m[Z][Z]
    local s
    if tr >= 0 then
      s = sqrt(tr + m[W][W])
      q.w = s * 0.5
      s = 0.5 / s
      q.x = (m[Z][Y] - m[Y][Z]) * s
      q.y = (m[X][Z] - m[Z][X]) * s
      q.z = (m[Y][X] - m[X][Y]) * s
    else
      local h = X
      if m[Y][Y] > m[X][X] then h = Y end
      if m[Z][Z] > m[h][h] then h = Z end
      if h == X then
        s = sqrt((m[X][X] - (m[Y][Y] + m[Z][Z])) + m[W][W])
        q.x = s * 0.5
        s = 0.5 / s
        q.y = (m[X][Y] + m[Y][X]) * s
        q.z = (m[Z][X] + m[X][Z]) * s
        q.w = (m[Z][Y] - m[Y][Z]) * s
      elseif h == Y then
        s = sqrt((m[Y][Y] - (m[Z][Z] + m[X][X])) + m[W][W])
        q.y = s * 0.5
        s = 0.5 / s
        q.z = (m[Y][Z] + m[Z][Y]) * s
        q.x = (m[X][Y] + m[Y][X]) * s
        q.w = (m[X][Z] - m[Z][X]) * s
      else
        s = sqrt((m[Z][Z] - (m[X][X] + m[Y][Y])) + m[W][W])
        q.z = s * 0.5
        s = 0.5 / s
        q.x = (m[Z][X] + m[X][Z]) * s
        q.y = (m[Y][Z] + m[Z][Y]) * s
        q.w = (m[Y][X] - m[X][Y]) * s
      end
    end
    if m[W][W] ~= 1 then q = quat_scale(q, 1 / sqrt(m[W][W])) end
    return q
  end

  local function polar_decomp(m)
    local mk = hmat_transpose3(m)
    local m_one, m_inf = hmat_norm(mk, true), hmat_norm(mk, false)
    local madjtk, det, e_one
    repeat
      madjtk = adjoint_transpose(mk)
      det = vdot(mk[X][X], mk[X][Y], mk[X][Z], madjtk[X][X], madjtk[X][Y], madjtk[X][Z])
      if det == 0 then
        do_rank2(mk, madjtk, mk)
        break
      end
      local madjt_one, madjt_inf = hmat_norm(madjtk, true), hmat_norm(madjtk, false)
      local gamma = sqrt(sqrt((madjt_one * madjt_inf) / (m_one * m_inf)) / abs(det))
      local g1, g2 = gamma * 0.5, 0.5 / (gamma * det)
      local ek = hmat_copy3(mk)
      for i = X, Z do
        for j = X, Z do
          mk[i][j] = g1*mk[i][j] + g2*madjtk[i][j]
          ek[i][j] = ek[i][j] - mk[i][j]
        end
      end
      e_one = hmat_norm(ek, true)
      m_one, m_inf = hmat_norm(mk, true), hmat_norm(mk, false)
    until e_one <= m_one * 1.0e-6

    local q = hmat_transpose3(mk)
    hmat_pad(q)
    local s = hmat_mult3(mk, m)
    hmat_pad(s)
    for i = X, Z do
      for j = i, Z do
        local value = 0.5 * (s[i][j] + s[j][i])
        s[i][j], s[j][i] = value, value
      end
    end
    return det, q, s
  end

  local function spect_decomp(s)
    local u = hmat_identity()
    local diag = { [X] = s[X][X], [Y] = s[Y][Y], [Z] = s[Z][Z] }
    local offd = { [X] = s[Y][Z], [Y] = s[Z][X], [Z] = s[X][Y] }
    local nxt = { [X] = Y, [Y] = Z, [Z] = X }
    for _ = 20, 1, -1 do
      if abs(offd[X]) + abs(offd[Y]) + abs(offd[Z]) == 0 then break end
      for i = Z, X, -1 do
        local p, q = nxt[i], nxt[nxt[i]]
        local fabs_off_di = abs(offd[i])
        if fabs_off_di > 0 then
          local h = diag[q] - diag[p]
          local g = 100 * fabs_off_di
          local t
          if abs(h) + g == abs(h) then
            t = offd[i] / h
          else
            local theta = 0.5 * h / offd[i]
            t = 1 / (abs(theta) + sqrt(theta*theta + 1))
            if theta < 0 then t = -t end
          end
          local c = 1 / sqrt(t*t + 1)
          local sn = t * c
          local tau = sn / (c + 1)
          local ta = t * offd[i]
          offd[i] = 0
          diag[p] = diag[p] - ta
          diag[q] = diag[q] + ta
          local offdq = offd[q]
          offd[q] = offd[q] - sn * (offd[p] + tau*offd[q])
          offd[p] = offd[p] + sn * (offdq - tau*offd[p])
          for j = Z, X, -1 do
            local a, b = u[j][p], u[j][q]
            u[j][p] = u[j][p] - sn * (b + tau*a)
            u[j][q] = u[j][q] + sn * (a - tau*b)
          end
        end
      end
    end
    return { x = diag[X], y = diag[Y], z = diag[Z], w = 1 }, u
  end

  local function snuggle(q, k)
    local function signed(negative, value)
      if negative then return -value end
      return value
    end
    local function swap(a, i, j)
      local t = a[i]
      a[i], a[j] = a[j], t
    end
    local function cycle(a, positive)
      if positive then
        local t = a[X]
        a[X], a[Y], a[Z] = a[Y], a[Z], t
      else
        local t = a[Z]
        a[Z], a[Y], a[X] = a[Y], a[X], t
      end
    end

    local p = q0001
    local ka = { [X] = k.x, [Y] = k.y, [Z] = k.z, [W] = 0 }
    local turn = -1
    if ka[X] == ka[Y] then
      if ka[X] == ka[Z] then turn = W else turn = Z end
    else
      if ka[X] == ka[Z] then turn = Y
      elseif ka[Y] == ka[Z] then turn = X end
    end

    if turn >= 0 then
      local qtoz
      if turn == W then
        return quat_conj(q)
      elseif turn == X then
        qtoz = qxtoz
        q = quat_mul_decomp(q, qtoz)
        swap(ka, X, Z)
      elseif turn == Y then
        qtoz = qytoz
        q = quat_mul_decomp(q, qtoz)
        swap(ka, Y, Z)
      else
        qtoz = q0001
      end
      q = quat_conj(q)
      local mag = {
        q.z*q.z + q.w*q.w - 0.5,
        q.x*q.z - q.y*q.w,
        q.y*q.z + q.x*q.w,
      }
      local neg = {}
      for i = X, Z do
        neg[i] = mag[i] < 0
        if neg[i] then mag[i] = -mag[i] end
      end
      local win
      if mag[X] > mag[Y] then
        if mag[X] > mag[Z] then win = X else win = Z end
      else
        if mag[Y] > mag[Z] then win = Y else win = Z end
      end
      if win == X then
        if neg[X] then p = q1000 else p = q0001 end
      elseif win == Y then
        if neg[Y] then p = qppmm else p = qpppp end
        cycle(ka, false)
      else
        if neg[Z] then p = qmpmm else p = qpppm end
        cycle(ka, true)
      end
      local qp = quat_mul_decomp(q, p)
      local t = sqrt(mag[win] + 0.5)
      p = quat_mul_decomp(p, quat_new(0, 0, -qp.z / t, qp.w / t))
      p = quat_mul_decomp(qtoz, quat_conj(p))
    else
      local qa = { [X] = q.x, [Y] = q.y, [Z] = q.z, [W] = q.w }
      local pa, neg = { [X] = 0, [Y] = 0, [Z] = 0, [W] = 0 }, {}
      local par = false
      for i = X, W do
        neg[i] = qa[i] < 0
        if neg[i] then qa[i] = -qa[i] end
        par = par ~= neg[i]
      end

      local lo, hi
      if qa[X] > qa[Y] then lo = X else lo = Y end
      if qa[Z] > qa[W] then hi = Z else hi = W end

      local xor1 = { [X] = Y, [Y] = X, [Z] = W, [W] = Z }
      if qa[lo] > qa[hi] then
        if qa[xor1[lo]] > qa[hi] then
          hi, lo = lo, xor1[lo]
        else
          hi, lo = lo, hi
        end
      else
        if qa[xor1[hi]] > qa[lo] then lo = xor1[hi] end
      end

      local all = (qa[X] + qa[Y] + qa[Z] + qa[W]) * 0.5
      local two = (qa[hi] + qa[lo]) * SQRTHALF
      local big = qa[hi]
      if all > two then
        if all > big then
          for i = X, W do pa[i] = signed(neg[i], 0.5) end
          cycle(ka, par)
        else
          pa[hi] = signed(neg[hi], 1)
        end
      else
        if two > big then
          pa[hi] = signed(neg[hi], SQRTHALF)
          pa[lo] = signed(neg[lo], SQRTHALF)
          if lo > hi then hi, lo = lo, hi end
          if hi == W then
            if lo == X then
              hi, lo = Y, Z
            elseif lo == Y then
              hi, lo = Z, X
            else
              hi, lo = X, Y
            end
          end
          swap(ka, hi, lo)
        else
          pa[hi] = signed(neg[hi], 1)
        end
      end
      p = quat_new(-pa[X], -pa[Y], -pa[Z], pa[W])
    end

    k.x, k.y, k.z = ka[X], ka[Y], ka[Z]
    return p
  end

  local function decomp_affine(a)
    local det, qmat, smat = polar_decomp(a)
    local f = 1
    if det < 0 then
      for i = X, Z do
        for j = X, Z do
          qmat[i][j] = -qmat[i][j]
        end
      end
      f = -1
    end

    local q = quat_from_hmat(qmat)
    local k, umat = spect_decomp(smat)
    local u = quat_from_hmat(umat)
    local p = snuggle(u, k)
    u = quat_mul_decomp(u, p)
    return a[X][W], a[Y][W], a[Z][W], q, k, u, f
  end

  -- Match osg::Matrixf::decompose: transpose to Graphics Gems affine form,
  -- polar-decompose the linear part, preserve determinant sign in the scale,
  -- and expose scale orientation for TransformM:tostring(). Box(transform)
  -- intentionally discards scale orientation afterwards, just like OpenMW.
  local function matrix_decompose(m)
    local a = {
      { m.m00, m.m10, m.m20, m.m30 },
      { m.m01, m.m11, m.m21, m.m31 },
      { m.m02, m.m12, m.m22, m.m32 },
      { 0, 0, 0, 1 },
    }
    local tx, ty, tz, q, k, u, f = decomp_affine(a)
    local smul = f
    if k.w ~= 0 then smul = smul / k.w end
    return tx, ty, tz, k.x*smul, k.y*smul, k.z*smul, q.x, q.y, q.z, q.w, u.x, u.y, u.z, u.w
  end

  local function quat_get_rotate_components(qx, qy, qz, qw)
    local s = sqrt(qx*qx + qy*qy + qz*qz)
    if s > 0 then
      local inv = 1 / s
      return 2 * atan2(s, qw), qx*inv, qy*inv, qz*inv
    end
    return 0, 0, 0, 1
  end

  local function angles_xz_from_forward(x, y, z)
    x, y, z = normalize_xyz(x, y, z)
    return -asin(z), atan2(x, y)
  end

  local function angles_zyx_from_forward_up(fx, fy, fz, ux, uy, uz)
    fx, fy, fz = normalize_xyz(fx, fy, fz)
    ux, uy, uz = normalize_xyz(ux, uy, uz)
    local y = -asin(ux)
    local x = atan2(uy, uz)
    local sx, cx = sin(x * 0.5), cos(x * 0.5)
    local sy, cy = sin(y * 0.5), cos(y * 0.5)
    -- osg::Quat::operator* is the opposite of the Hamilton helper used here.
    -- OpenMW computes (Quat(x, X) * Quat(y, Y)) * forward, i.e. Hamilton Y*X.
    local qx, qy, qz, qw = quat_mul_components(0, sy, 0, cy, sx, 0, 0, cx)
    local zx, zy = quat_apply_xyz(qx, qy, qz, qw, fx, fy, fz)
    return atan2(zx, zy), y, x
  end

  local function transformm_tostring(m)
    local tx, ty, tz, sx, sy, sz, qx, qy, qz, qw, sox, soy, soz, sow = matrix_decompose(m)
    local s = 'TransformM{ '
    if tx*tx + ty*ty + tz*tz > 0 then
      s = s..('move(%.38g, %.38g, %.38g) '):format(tx, ty, tz)
    end
    local angle, ax, ay, az = quat_get_rotate_components(qx, qy, qz, qw)
    if angle ~= 0 then
      s = s..('rotation(angle=%.38g, axis=(%.38g, %.38g, %.38g)) '):format(angle, ax, ay, az)
    end
    if sx ~= 1 or sy ~= 1 or sz ~= 1 then
      s = s..('scale(%.38g, %.38g, %.38g) '):format(sx, sy, sz)
    end
    angle, ax, ay, az = quat_get_rotate_components(sox, soy, soz, sow)
    if angle ~= 0 then
      s = s..('rotation(angle=%.38g, axis=(%.38g, %.38g, %.38g)) '):format(angle, ax, ay, az)
    end
    return s..'}'
  end

  local function transformq_tostring(q)
    local angle, ax, ay, az = quat_get_rotate_components(q.qx, q.qy, q.qz, q.qw)
    return ('TransformQ{ rotation(angle=%.38g, axis=(%.38g, %.38g, %.38g)) }'):
      format(angle, ax, ay, az)
  end

  local function osg_matrix_component_equal(a, b)
    -- osg::Matrixf::operator== delegates to compare(), which uses ordering
    -- checks rather than IEEE ==. Preserve that compatibility quirk here.
    return not (a < b or b < a)
  end

  local function transformm_equal(a, b)
    return is_transformm(a) and is_transformm(b) and
      osg_matrix_component_equal(a.m00, b.m00) and osg_matrix_component_equal(a.m01, b.m01) and osg_matrix_component_equal(a.m02, b.m02) and
      osg_matrix_component_equal(a.m10, b.m10) and osg_matrix_component_equal(a.m11, b.m11) and osg_matrix_component_equal(a.m12, b.m12) and
      osg_matrix_component_equal(a.m20, b.m20) and osg_matrix_component_equal(a.m21, b.m21) and osg_matrix_component_equal(a.m22, b.m22) and
      osg_matrix_component_equal(a.m30, b.m30) and osg_matrix_component_equal(a.m31, b.m31) and osg_matrix_component_equal(a.m32, b.m32)
  end

  local function transformq_equal(a, b)
    return is_transformq(a) and is_transformq(b) and
      a.qx == b.qx and a.qy == b.qy and a.qz == b.qz and a.qw == b.qw
  end

  local function transformm_mt()
    local Methods = {}
    local MT = {}
    MT.__mul = function(a, b)
      if not is_transformm(a) then err_type('transform', 'multiplication') end
      if is_vec3(b) then return matrix_apply_vec(a, b) end
      if is_transformm(b) then return matrix_mul(b, a) end
      if is_transformq(b) then return matrix_mul(matrix_from_quat(b), a) end
      err_type('transform', 'multiplication')
    end
    MT.__eq = transformm_equal
    MT.__tostring = transformm_tostring
    Methods.apply = function(a, b)
      if not is_transformm(a) then err_type('transform', 'apply') end
      if is_vec3(b) then return matrix_apply_vec(a, b) end
      error('vector3 expected for apply', 3)
    end
    Methods.inverse = function(m)
      if not is_transformm(m) then err_type('transform', 'inverse') end
      return matrix_inverse(m)
    end
    Methods.getYaw = function(m)
      if not is_transformm(m) then err_type('transform', 'getYaw') end
      local _, yaw = angles_xz_from_forward(m.m10, m.m11, m.m12)
      return yaw
    end
    Methods.getPitch = function(m)
      if not is_transformm(m) then err_type('transform', 'getPitch') end
      local pitch = angles_xz_from_forward(m.m10, m.m11, m.m12)
      return pitch
    end
    Methods.getAnglesXZ = function(m)
      if not is_transformm(m) then err_type('transform', 'getAnglesXZ') end
      return angles_xz_from_forward(m.m10, m.m11, m.m12)
    end
    Methods.getAnglesZYX = function(m)
      if not is_transformm(m) then err_type('transform', 'getAnglesZYX') end
      return angles_zyx_from_forward_up(m.m10, m.m11, m.m12, m.m20, m.m21, m.m22)
    end
    MT.__index = function(_, key) return Methods[key] end
    return MT
  end

  local function transformq_mt()
    local Methods = {}
    local MT = {}
    MT.__mul = function(a, b)
      if not is_transformq(a) then err_type('transform', 'multiplication') end
      if is_vec3(b) then return vector3(quat_apply_xyz(a.qx, a.qy, a.qz, a.qw, b.x, b.y, b.z)) end
      if is_transformq(b) then return quat_mul(a, b) end
      if is_transformm(b) then return matrix_mul(b, matrix_from_quat(a)) end
      err_type('transform', 'multiplication')
    end
    MT.__eq = transformq_equal
    MT.__tostring = transformq_tostring
    Methods.apply = function(a, b)
      if not is_transformq(a) then err_type('transform', 'apply') end
      if is_vec3(b) then return vector3(quat_apply_xyz(a.qx, a.qy, a.qz, a.qw, b.x, b.y, b.z)) end
      error('vector3 expected for apply', 3)
    end
    Methods.inverse = function(q)
      if not is_transformq(q) then err_type('transform', 'inverse') end
      return quat_inverse(q)
    end
    Methods.getYaw = function(q)
      if not is_transformq(q) then err_type('transform', 'getYaw') end
      local x, y, z = quat_apply_xyz(q.qx, q.qy, q.qz, q.qw, 0, 1, 0)
      local _, yaw = angles_xz_from_forward(x, y, z)
      return yaw
    end
    Methods.getPitch = function(q)
      if not is_transformq(q) then err_type('transform', 'getPitch') end
      local x, y, z = quat_apply_xyz(q.qx, q.qy, q.qz, q.qw, 0, 1, 0)
      local pitch = angles_xz_from_forward(x, y, z)
      return pitch
    end
    Methods.getAnglesXZ = function(q)
      if not is_transformq(q) then err_type('transform', 'getAnglesXZ') end
      return angles_xz_from_forward(quat_apply_xyz(q.qx, q.qy, q.qz, q.qw, 0, 1, 0))
    end
    Methods.getAnglesZYX = function(q)
      if not is_transformq(q) then err_type('transform', 'getAnglesZYX') end
      local fx, fy, fz = quat_apply_xyz(q.qx, q.qy, q.qz, q.qw, 0, 1, 0)
      local ux, uy, uz = quat_apply_xyz(q.qx, q.qy, q.qz, q.qw, 0, 0, 1)
      return angles_zyx_from_forward_up(fx, fy, fz, ux, uy, uz)
    end
    MT.__index = function(_, key) return Methods[key] end
    return MT
  end

  local function vec2_mt(immutable, is_self, is_other)
    local Methods = {}
    local MT = {}
    if immutable then
      MT.__add = function(a, b)
        if not is_self(a) then err_type('vector2', 'addition') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x+b.x, a.y+b.y) end
        err_type('vector2', 'addition')
      end
      MT.__sub = function(a, b)
        if not is_self(a) then err_type('vector2', 'subtraction') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x-b.x, a.y-b.y) end
        err_type('vector2', 'subtraction')
      end
      MT.__unm = function(v) return immutable_vector2(-v.x, -v.y) end
      MT.__eq = function(a, b)
        return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y
      end
      MT.__mul = function(a, b)
        if type(a) == 'number' then
          if not is_self(b) then err_type('vector2', 'multiplication') end
          return immutable_vector2(a*b.x, a*b.y)
        end
        if not is_self(a) then err_type('vector2', 'multiplication') end
        if type(b) == 'number' then return immutable_vector2(a.x*b, a.y*b) end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
        err_type('vector2', 'multiplication')
      end
      MT.__div = function(a, scalar)
        if not is_self(a) then err_type('vector2', 'division') end
        if type(scalar) ~= 'number' then err_scalar('vector2', 'divided') end
        return immutable_vector2(a.x/scalar, a.y/scalar)
      end
      MT.__tostring = function(v) return ('(%.38g, %.38g)'):format(v.x, v.y) end
      MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y) end
      Methods.length2 = function(v)
        if not is_self(v) then err_type('vector2', 'length2') end
        return v.x*v.x + v.y*v.y
      end
      Methods.length = function(v)
        if not is_self(v) then err_type('vector2', 'length') end
        return sqrt(v.x*v.x + v.y*v.y)
      end
      Methods.normalize = function(v)
        if not is_self(v) then err_type('vector2', 'normalize') end
        local len = sqrt(v.x*v.x + v.y*v.y)
        if len == 0 then return immutable_vector2(0, 0), len end
        return immutable_vector2(v.x/len, v.y/len), len
      end
      Methods.dot = function(a, b)
        if not is_self(a) then err_type('vector2', 'dot') end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
        err_type('vector2', 'dot')
      end
      Methods.emul = function(a, b)
        if not is_self(a) then err_type('vector2', 'element multiplication') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x*b.x, a.y*b.y) end
        err_type('vector2', 'element multiplication')
      end
      Methods.ediv = function(a, b)
        if not is_self(a) then err_type('vector2', 'element division') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x/b.x, a.y/b.y) end
        err_type('vector2', 'element division')
      end
      Methods.rotate = function(v, angle)
        if not is_self(v) then err_type('vector2', 'rotate') end
        if type(angle) ~= 'number' then badarg(2, 'rotate') end
        local c, s = cos(angle), sin(angle)
        return immutable_vector2(v.x*c - v.y*s, v.x*s + v.y*c)
      end
      Methods.is = function(v) return is_self(v) or is_other(v) end
      MT.__index = swizzle_index(Methods, swizzle2_component, true)
      return MT
    end
    MT.__add = function(a, b)
      if not is_self(a) then err_type('vector2', 'addition') end
      if is_self(b) or is_other(b) then return vector2(a.x+b.x, a.y+b.y) end
      err_type('vector2', 'addition')
    end
    MT.__sub = function(a, b)
      if not is_self(a) then err_type('vector2', 'subtraction') end
      if is_self(b) or is_other(b) then return vector2(a.x-b.x, a.y-b.y) end
      err_type('vector2', 'subtraction')
    end
    MT.__unm = function(v) return vector2(-v.x, -v.y) end
    MT.__eq = function(a, b)
      return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y
    end
    MT.__mul = function(a, b)
      if type(a) == 'number' then
        if not is_self(b) then err_type('vector2', 'multiplication') end
        return vector2(a*b.x, a*b.y)
      end
      if not is_self(a) then err_type('vector2', 'multiplication') end
      if type(b) == 'number' then return vector2(a.x*b, a.y*b) end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
      err_type('vector2', 'multiplication')
    end
    MT.__div = function(a, scalar)
      if not is_self(a) then err_type('vector2', 'division') end
      if type(scalar) ~= 'number' then err_scalar('vector2', 'divided') end
      return vector2(a.x/scalar, a.y/scalar)
    end
    MT.__tostring = function(v) return ('(%.38g, %.38g)'):format(v.x, v.y) end
    MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y) end
    Methods.length2 = function(v)
      if not is_self(v) then err_type('vector2', 'length2') end
      return v.x*v.x + v.y*v.y
    end
    Methods.length = function(v)
      if not is_self(v) then err_type('vector2', 'length') end
      return sqrt(v.x*v.x + v.y*v.y)
    end
    Methods.normalize = function(v)
      if not is_self(v) then err_type('vector2', 'normalize') end
      local len = sqrt(v.x*v.x + v.y*v.y)
      if len == 0 then return vector2(0, 0), len end
      return vector2(v.x/len, v.y/len), len
    end
    Methods.dot = function(a, b)
      if not is_self(a) then err_type('vector2', 'dot') end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
      err_type('vector2', 'dot')
    end
    Methods.emul = function(a, b)
      if not is_self(a) then err_type('vector2', 'element multiplication') end
      if is_self(b) or is_other(b) then return vector2(a.x*b.x, a.y*b.y) end
      err_type('vector2', 'element multiplication')
    end
    Methods.ediv = function(a, b)
      if not is_self(a) then err_type('vector2', 'element division') end
      if is_self(b) or is_other(b) then return vector2(a.x/b.x, a.y/b.y) end
      err_type('vector2', 'element division')
    end
    Methods.rotate = function(v, angle)
      if not is_self(v) then err_type('vector2', 'rotate') end
      if type(angle) ~= 'number' then badarg(2, 'rotate') end
      local c, s = cos(angle), sin(angle)
      return vector2(v.x*c - v.y*s, v.x*s + v.y*c)
    end
    Methods.is = function(v) return is_self(v) or is_other(v) end
    MT.__index = swizzle_index(Methods, swizzle2_component, false)
    return MT
  end

  local function vec3_mt(immutable, is_self, is_other)
    local Methods = {}
    local MT = {}
    if immutable then
      MT.__add = function(a, b)
        if not is_self(a) then err_type('vector3', 'addition') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x+b.x, a.y+b.y, a.z+b.z) end
        err_type('vector3', 'addition')
      end
      MT.__sub = function(a, b)
        if not is_self(a) then err_type('vector3', 'subtraction') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x-b.x, a.y-b.y, a.z-b.z) end
        err_type('vector3', 'subtraction')
      end
      MT.__unm = function(v) return immutable_vector3(-v.x, -v.y, -v.z) end
      MT.__eq = function(a, b)
        return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z
      end
      MT.__mul = function(a, b)
        if type(a) == 'number' then
          if not is_self(b) then err_type('vector3', 'multiplication') end
          return immutable_vector3(a*b.x, a*b.y, a*b.z)
        end
        if not is_self(a) then err_type('vector3', 'multiplication') end
        if type(b) == 'number' then return immutable_vector3(a.x*b, a.y*b, a.z*b) end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
        err_type('vector3', 'multiplication')
      end
      MT.__div = function(a, scalar)
        if not is_self(a) then err_type('vector3', 'division') end
        if type(scalar) ~= 'number' then err_scalar('vector3', 'divided') end
        return immutable_vector3(a.x/scalar, a.y/scalar, a.z/scalar)
      end
      MT.__pow = function(a, b)
        if not is_self(a) then err_type('vector3', 'cross') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
        err_type('vector3', 'cross')
      end
      MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g)'):format(v.x, v.y, v.z) end
      MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
      Methods.length2 = function(v)
        if not is_self(v) then err_type('vector3', 'length2') end
        return v.x*v.x + v.y*v.y + v.z*v.z
      end
      Methods.length = function(v)
        if not is_self(v) then err_type('vector3', 'length') end
        return sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
      end
      Methods.normalize = function(v)
        if not is_self(v) then err_type('vector3', 'normalize') end
        local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
        if len == 0 then return immutable_vector3(0, 0, 0), len end
        return immutable_vector3(v.x/len, v.y/len, v.z/len), len
      end
      Methods.dot = function(a, b)
        if not is_self(a) then err_type('vector3', 'dot') end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
        err_type('vector3', 'dot')
      end
      Methods.cross = function(a, b)
        if not is_self(a) then err_type('vector3', 'cross') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
        err_type('vector3', 'cross')
      end
      Methods.emul = function(a, b)
        if not is_self(a) then err_type('vector3', 'element multiplication') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x*b.x, a.y*b.y, a.z*b.z) end
        err_type('vector3', 'element multiplication')
      end
      Methods.ediv = function(a, b)
        if not is_self(a) then err_type('vector3', 'element division') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x/b.x, a.y/b.y, a.z/b.z) end
        err_type('vector3', 'element division')
      end
      Methods.is = function(v) return is_self(v) or is_other(v) end
      MT.__index = swizzle_index(Methods, swizzle3_component, true)
      return MT
    end
    MT.__add = function(a, b)
      if not is_self(a) then err_type('vector3', 'addition') end
      if is_self(b) or is_other(b) then return vector3(a.x+b.x, a.y+b.y, a.z+b.z) end
      err_type('vector3', 'addition')
    end
    MT.__sub = function(a, b)
      if not is_self(a) then err_type('vector3', 'subtraction') end
      if is_self(b) or is_other(b) then return vector3(a.x-b.x, a.y-b.y, a.z-b.z) end
      err_type('vector3', 'subtraction')
    end
    MT.__unm = function(v) return vector3(-v.x, -v.y, -v.z) end
    MT.__eq = function(a, b)
      return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z
    end
    MT.__mul = function(a, b)
      if type(a) == 'number' then
        if not is_self(b) then err_type('vector3', 'multiplication') end
        return vector3(a*b.x, a*b.y, a*b.z)
      end
      if not is_self(a) then err_type('vector3', 'multiplication') end
      if type(b) == 'number' then return vector3(a.x*b, a.y*b, a.z*b) end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
      err_type('vector3', 'multiplication')
    end
    MT.__div = function(a, scalar)
      if not is_self(a) then err_type('vector3', 'division') end
      if type(scalar) ~= 'number' then err_scalar('vector3', 'divided') end
      return vector3(a.x/scalar, a.y/scalar, a.z/scalar)
    end
    MT.__pow = function(a, b)
      if not is_self(a) then err_type('vector3', 'cross') end
      if is_self(b) or is_other(b) then return vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
      err_type('vector3', 'cross')
    end
    MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g)'):format(v.x, v.y, v.z) end
    MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
    Methods.length2 = function(v)
      if not is_self(v) then err_type('vector3', 'length2') end
      return v.x*v.x + v.y*v.y + v.z*v.z
    end
    Methods.length = function(v)
      if not is_self(v) then err_type('vector3', 'length') end
      return sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
    end
    Methods.normalize = function(v)
      if not is_self(v) then err_type('vector3', 'normalize') end
      local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
      if len == 0 then return vector3(0, 0, 0), len end
      return vector3(v.x/len, v.y/len, v.z/len), len
    end
    Methods.dot = function(a, b)
      if not is_self(a) then err_type('vector3', 'dot') end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
      err_type('vector3', 'dot')
    end
    Methods.cross = function(a, b)
      if not is_self(a) then err_type('vector3', 'cross') end
      if is_self(b) or is_other(b) then return vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
      err_type('vector3', 'cross')
    end
    Methods.emul = function(a, b)
      if not is_self(a) then err_type('vector3', 'element multiplication') end
      if is_self(b) or is_other(b) then return vector3(a.x*b.x, a.y*b.y, a.z*b.z) end
      err_type('vector3', 'element multiplication')
    end
    Methods.ediv = function(a, b)
      if not is_self(a) then err_type('vector3', 'element division') end
      if is_self(b) or is_other(b) then return vector3(a.x/b.x, a.y/b.y, a.z/b.z) end
      err_type('vector3', 'element division')
    end
    Methods.is = function(v) return is_self(v) or is_other(v) end
    MT.__index = swizzle_index(Methods, swizzle3_component, false)
    return MT
  end

  local function vec4_mt(immutable, is_self, is_other)
    local Methods = {}
    local MT = {}
    if immutable then
      MT.__add = function(a, b)
        if not is_self(a) then err_type('vector4', 'addition') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x+b.x, a.y+b.y, a.z+b.z, a.w+b.w) end
        err_type('vector4', 'addition')
      end
      MT.__sub = function(a, b)
        if not is_self(a) then err_type('vector4', 'subtraction') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x-b.x, a.y-b.y, a.z-b.z, a.w-b.w) end
        err_type('vector4', 'subtraction')
      end
      MT.__unm = function(v) return immutable_vector4(-v.x, -v.y, -v.z, -v.w) end
      MT.__eq = function(a, b)
        return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
      end
      MT.__mul = function(a, b)
        if type(a) == 'number' then
          if not is_self(b) then err_type('vector4', 'multiplication') end
          return immutable_vector4(a*b.x, a*b.y, a*b.z, a*b.w)
        end
        if not is_self(a) then err_type('vector4', 'multiplication') end
        if type(b) == 'number' then return immutable_vector4(a.x*b, a.y*b, a.z*b, a.w*b) end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
        err_type('vector4', 'multiplication')
      end
      MT.__div = function(a, scalar)
        if not is_self(a) then err_type('vector4', 'division') end
        if type(scalar) ~= 'number' then err_scalar('vector4', 'divided') end
        return immutable_vector4(a.x/scalar, a.y/scalar, a.z/scalar, a.w/scalar)
      end
      MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g, %.38g)'):format(v.x, v.y, v.z, v.w) end
      MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w) end
      Methods.length2 = function(v)
        if not is_self(v) then err_type('vector4', 'length2') end
        return v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w
      end
      Methods.length = function(v)
        if not is_self(v) then err_type('vector4', 'length') end
        return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
      end
      Methods.normalize = function(v)
        if not is_self(v) then err_type('vector4', 'normalize') end
        local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
        if len == 0 then return immutable_vector4(0, 0, 0, 0), len end
        return immutable_vector4(v.x/len, v.y/len, v.z/len, v.w/len), len
      end
      Methods.dot = function(a, b)
        if not is_self(a) then err_type('vector4', 'dot') end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
        err_type('vector4', 'dot')
      end
      Methods.emul = function(a, b)
        if not is_self(a) then err_type('vector4', 'element multiplication') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x*b.x, a.y*b.y, a.z*b.z, a.w*b.w) end
        err_type('vector4', 'element multiplication')
      end
      Methods.ediv = function(a, b)
        if not is_self(a) then err_type('vector4', 'element division') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x/b.x, a.y/b.y, a.z/b.z, a.w/b.w) end
        err_type('vector4', 'element division')
      end
      Methods.is = function(v) return is_self(v) or is_other(v) end
      MT.__index = swizzle_index(Methods, swizzle4_component, true)
      return MT
    end
    MT.__add = function(a, b)
      if not is_self(a) then err_type('vector4', 'addition') end
      if is_self(b) or is_other(b) then return vector4(a.x+b.x, a.y+b.y, a.z+b.z, a.w+b.w) end
      err_type('vector4', 'addition')
    end
    MT.__sub = function(a, b)
      if not is_self(a) then err_type('vector4', 'subtraction') end
      if is_self(b) or is_other(b) then return vector4(a.x-b.x, a.y-b.y, a.z-b.z, a.w-b.w) end
      err_type('vector4', 'subtraction')
    end
    MT.__unm = function(v) return vector4(-v.x, -v.y, -v.z, -v.w) end
    MT.__eq = function(a, b)
      return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
    end
    MT.__mul = function(a, b)
      if type(a) == 'number' then
        if not is_self(b) then err_type('vector4', 'multiplication') end
        return vector4(a*b.x, a*b.y, a*b.z, a*b.w)
      end
      if not is_self(a) then err_type('vector4', 'multiplication') end
      if type(b) == 'number' then return vector4(a.x*b, a.y*b, a.z*b, a.w*b) end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
      err_type('vector4', 'multiplication')
    end
    MT.__div = function(a, scalar)
      if not is_self(a) then err_type('vector4', 'division') end
      if type(scalar) ~= 'number' then err_scalar('vector4', 'divided') end
      return vector4(a.x/scalar, a.y/scalar, a.z/scalar, a.w/scalar)
    end
    MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g, %.38g)'):format(v.x, v.y, v.z, v.w) end
    MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w) end
    Methods.length2 = function(v)
      if not is_self(v) then err_type('vector4', 'length2') end
      return v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w
    end
    Methods.length = function(v)
      if not is_self(v) then err_type('vector4', 'length') end
      return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
    end
    Methods.normalize = function(v)
      if not is_self(v) then err_type('vector4', 'normalize') end
      local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
      if len == 0 then return vector4(0, 0, 0, 0), len end
      return vector4(v.x/len, v.y/len, v.z/len, v.w/len), len
    end
    Methods.dot = function(a, b)
      if not is_self(a) then err_type('vector4', 'dot') end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
      err_type('vector4', 'dot')
    end
    Methods.emul = function(a, b)
      if not is_self(a) then err_type('vector4', 'element multiplication') end
      if is_self(b) or is_other(b) then return vector4(a.x*b.x, a.y*b.y, a.z*b.z, a.w*b.w) end
      err_type('vector4', 'element multiplication')
    end
    Methods.ediv = function(a, b)
      if not is_self(a) then err_type('vector4', 'element division') end
      if is_self(b) or is_other(b) then return vector4(a.x/b.x, a.y/b.y, a.z/b.z, a.w/b.w) end
      err_type('vector4', 'element division')
    end
    Methods.is = function(v) return is_self(v) or is_other(v) end
    MT.__index = swizzle_index(Methods, swizzle4_component, false)
    return MT
  end

  local function box_vertex(b, x, y, z)
    local qx, qy, qz, qw = b.qx, b.qy, b.qz, b.qw
    local tx = 2 * (qy*z - qz*y)
    local ty = 2 * (qz*x - qx*z)
    local tz = 2 * (qx*y - qy*x)
    return immutable_vector3(
      b.center.x + x + qw*tx + qy*tz - qz*ty,
      b.center.y + y + qw*ty + qz*tx - qx*tz,
      b.center.z + z + qw*tz + qx*ty - qy*tx)
  end

  local function box_as_transform(b)
    local r = matrix_from_quat_components(b.qx, b.qy, b.qz, b.qw)
    local hx, hy, hz = b.halfSize.x, b.halfSize.y, b.halfSize.z
    return transformm(
      r.m00*hx, r.m01*hx, r.m02*hx,
      r.m10*hy, r.m11*hy, r.m12*hy,
      r.m20*hz, r.m21*hz, r.m22*hz,
      b.center.x, b.center.y, b.center.z)
  end

  local function box_from_transformm(t)
    local tx, ty, tz, sx, sy, sz, qx, qy, qz, qw = matrix_decompose(t)
    return box(immutable_vector3(tx, ty, tz), immutable_vector3(sx, sy, sz), qx, qy, qz, qw)
  end

  local function box_from_transformq(t)
    return box(immutable_vector3(0, 0, 0), immutable_vector3(1, 1, 1), t.qx, t.qy, t.qz, t.qw)
  end

  local function box_mt()
    local MT = {}
    MT.__index = function(b, key)
      if key == 'transform' then
        return box_as_transform(b)
      end
      if key == 'vertices' then
        local hx, hy, hz = b.halfSize.x, b.halfSize.y, b.halfSize.z
        return {
          box_vertex(b, -hx, -hy, -hz),
          box_vertex(b,  hx, -hy, -hz),
          box_vertex(b,  hx,  hy, -hz),
          box_vertex(b, -hx,  hy, -hz),
          box_vertex(b, -hx, -hy,  hz),
          box_vertex(b,  hx, -hy,  hz),
          box_vertex(b,  hx,  hy,  hz),
          box_vertex(b, -hx,  hy,  hz),
        }
      end
      return nil
    end
    MT.__eq = function(a, b)
      return is_box(a) and is_box(b) and
        a.center.x == b.center.x and a.center.y == b.center.y and a.center.z == b.center.z and
        a.halfSize.x == b.halfSize.x and a.halfSize.y == b.halfSize.y and a.halfSize.z == b.halfSize.z and
        a.qx == b.qx and a.qy == b.qy and a.qz == b.qz and a.qw == b.qw
    end
    MT.__tostring = function(b)
      return ('Box{ center(%.38g, %.38g, %.38g) halfSize(%.38g, %.38g, %.38g) }'):
        format(b.center.x, b.center.y, b.center.z, b.halfSize.x, b.halfSize.y, b.halfSize.z)
    end
    return MT
  end

  local function box_constructor(...)
    local n = select('#', ...)
    if n == 1 then
      local transform = ...
      if is_transformm(transform) then return box_from_transformm(transform) end
      if is_transformq(transform) then return box_from_transformq(transform) end
      error('box transform constructor requires a transform argument', 3)
    end
    if n ~= 2 then
      error('box constructor requires center and halfSize vector3 arguments', 3)
    end
    local center, halfSize = ...
    if not (is_mvec3(center) or is_ivec3(center)) then
      error('box constructor requires center to be a vector3', 3)
    end
    if not (is_mvec3(halfSize) or is_ivec3(halfSize)) then
      error('box constructor requires halfSize to be a vector3', 3)
    end
    return box(immutable_vector3(center.x, center.y, center.z), immutable_vector3(halfSize.x, halfSize.y, halfSize.z), 0, 0, 0, 1)
  end

  local function transform_vector_or_xyz(name, ...)
    local n = select('#', ...)
    if n == 1 then
      local v = ...
      if is_vec3(v) then return v.x, v.y, v.z end
    elseif n == 3 then
      for i = 1, 3 do
        if type(select(i, ...)) ~= 'number' then badarg(i, name) end
      end
      return ...
    end
    error(name..' requires a vector3 or three numeric arguments', 3)
  end

  local function transform_move_constructor(...)
    local x, y, z = transform_vector_or_xyz('transform.move', ...)
    return transformm(1, 0, 0, 0, 1, 0, 0, 0, 1, x, y, z)
  end

  local function transform_scale_constructor(...)
    local x, y, z = transform_vector_or_xyz('transform.scale', ...)
    return transformm(x, 0, 0, 0, y, 0, 0, 0, z, 0, 0, 0)
  end

  local function transform_rotate_constructor(...)
    if select('#', ...) ~= 2 then
      error('transform.rotate requires angle and axis arguments', 3)
    end
    local angle, axis = ...
    if type(angle) ~= 'number' then badarg(1, 'transform.rotate') end
    if not is_vec3(axis) then error('transform.rotate requires axis to be a vector3', 3) end
    return quat_from_axis_angle(angle, axis.x, axis.y, axis.z)
  end

  local function transform_rotatex_constructor(...)
    if select('#', ...) ~= 1 then error('transform.rotateX requires exactly one numeric argument', 3) end
    local angle = ...
    if type(angle) ~= 'number' then badarg(1, 'transform.rotateX') end
    return quat_from_axis_angle(angle, -1, 0, 0)
  end

  local function transform_rotatey_constructor(...)
    if select('#', ...) ~= 1 then error('transform.rotateY requires exactly one numeric argument', 3) end
    local angle = ...
    if type(angle) ~= 'number' then badarg(1, 'transform.rotateY') end
    return quat_from_axis_angle(angle, 0, -1, 0)
  end

  local function transform_rotatez_constructor(...)
    if select('#', ...) ~= 1 then error('transform.rotateZ requires exactly one numeric argument', 3) end
    local angle = ...
    if type(angle) ~= 'number' then badarg(1, 'transform.rotateZ') end
    return quat_from_axis_angle(angle, 0, 0, -1)
  end

  vector2 = ffi.metatype(vector2_type, vec2_mt(false, is_mvec2, is_ivec2))
  immutable_vector2 = ffi.metatype(immutable_vector2_type, vec2_mt(true, is_ivec2, is_mvec2))
  vector3 = ffi.metatype(vector3_type, vec3_mt(false, is_mvec3, is_ivec3))
  immutable_vector3 = ffi.metatype(immutable_vector3_type, vec3_mt(true, is_ivec3, is_mvec3))
  vector4 = ffi.metatype(vector4_type, vec4_mt(false, is_mvec4, is_ivec4))
  immutable_vector4 = ffi.metatype(immutable_vector4_type, vec4_mt(true, is_ivec4, is_mvec4))
  transformm = ffi.metatype(transformm_type, transformm_mt())
  transformq = ffi.metatype(transformq_type, transformq_mt())
  box = ffi.metatype(box_type, box_mt())
  return { vector2, vector3, vector4, immutable_vector2, immutable_vector3, immutable_vector4, box_constructor,
    transform_move_constructor, transform_scale_constructor, transform_rotate_constructor,
    transform_rotatex_constructor, transform_rotatey_constructor, transform_rotatez_constructor,
    transformq(0, 0, 0, 1) }
end

local function ensure_geometry()
  local vector2 = vector2_ctor
  if not vector2 then
    local ffi, cached = loadffi()
    local ctors = cached or build_geometry(ffi)
    vector2_ctor, vector3_ctor, vector4_ctor = ctors[1], ctors[2], ctors[3]
    immutable_vector2_ctor, immutable_vector3_ctor, immutable_vector4_ctor = ctors[4], ctors[5], ctors[6]
    box_ctor = ctors[7]
    transform_move_ctor, transform_scale_ctor, transform_rotate_ctor = ctors[8], ctors[9], ctors[10]
    transform_rotatex_ctor, transform_rotatey_ctor, transform_rotatez_ctor = ctors[11], ctors[12], ctors[13]
    transform_identity_value = ctors[14]
    if not cached then loadffi(ctors) end
  end
end

math.vector2 = function(...)
  check_constructor('vector2', 2, ...)
  local x, y = ...
  ensure_geometry()
  return vector2_ctor(x, y)
end

math.vector3 = function(...)
  check_constructor('vector3', 3, ...)
  local x, y, z = ...
  ensure_geometry()
  return vector3_ctor(x, y, z)
end

math.vector4 = function(...)
  check_constructor('vector4', 4, ...)
  local x, y, z, w = ...
  ensure_geometry()
  return vector4_ctor(x, y, z, w)
end

math.immutableVector2 = function(...)
  check_constructor('immutableVector2', 2, ...)
  local x, y = ...
  ensure_geometry()
  return immutable_vector2_ctor(x, y)
end

math.immutableVector3 = function(...)
  check_constructor('immutableVector3', 3, ...)
  local x, y, z = ...
  ensure_geometry()
  return immutable_vector3_ctor(x, y, z)
end

math.immutableVector4 = function(...)
  check_constructor('immutableVector4', 4, ...)
  local x, y, z, w = ...
  ensure_geometry()
  return immutable_vector4_ctor(x, y, z, w)
end

math.box = function(...)
  local n = select('#', ...)
  if n ~= 1 and n ~= 2 then
    error('box constructor requires center and halfSize vector3 arguments', 2)
  end
  ensure_geometry()
  return box_ctor(...)
end

local transform_table = {
  move = function(...)
    ensure_geometry()
    return transform_move_ctor(...)
  end,
  scale = function(...)
    ensure_geometry()
    return transform_scale_ctor(...)
  end,
  rotate = function(...)
    ensure_geometry()
    return transform_rotate_ctor(...)
  end,
  rotateX = function(...)
    ensure_geometry()
    return transform_rotatex_ctor(...)
  end,
  rotateY = function(...)
    ensure_geometry()
    return transform_rotatey_ctor(...)
  end,
  rotateZ = function(...)
    ensure_geometry()
    return transform_rotatez_ctor(...)
  end,
}

math.transform = setmetatable(transform_table, {
  __index = function(t, key)
    if key == 'identity' then
      ensure_geometry()
      rawset(t, key, transform_identity_value)
      return transform_identity_value
    end
    return nil
  end,
})
