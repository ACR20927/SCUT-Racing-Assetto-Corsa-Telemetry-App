-- Shared sender/recorder contract. This file contains column definitions only;
-- it is not a telemetry payload. Keep the recorder copy identical.
local channels = {eventName = 'VehicleTelemetry', fields = {}, byName = {}}
channels.baseColumns = {
  {'time_s', 's'}, {'speed_kmh', 'km/h'}, {'steering_angle_deg', 'deg'},
  {'throttle_pct', '%'}, {'brake_pct', '%'}, {'clutch_pct', '%'},
  {'position_world_x_m', 'm'}, {'position_world_y_m', 'm'}, {'position_world_z_m', 'm'},
  {'acceleration_longitudinal_g', 'g'}, {'acceleration_lateral_g', 'g'},
  {'acceleration_vertical_g', 'g'}
}

local function add(name, unit)
  local definition = {name = name, unit = unit}
  channels.fields[#channels.fields + 1] = definition
  channels.byName[name] = definition
end

for _, wheel in ipairs({'FL', 'FR', 'RL', 'RR'}) do
  add(wheel .. '_motor_torque_command_Nm', 'N*m')
end
add('motor_ctrl_mode', '')
add('yaw_rate_actual_radps', 'rad/s')
add('yaw_rate_target_radps', 'rad/s')
for _, wheel in ipairs({'FL', 'FR', 'RL', 'RR'}) do
  -- The original AC raw tyre channels retain their original signs and meaning.
  add(wheel .. '_tyre_fx_raw_N', 'N')
  add(wheel .. '_tyre_fy_raw_N', 'N')
  add(wheel .. '_tyre_normal_load_N', 'N')
  -- Physical chassis basis: X=side, Y=up, Z=look (forward).
  add(wheel .. '_tyre_force_body_x_N', 'N')
  add(wheel .. '_tyre_force_body_y_N', 'N')
  add(wheel .. '_tyre_force_body_z_N', 'N')
  add(wheel .. '_tyre_slip_angle_rad', 'rad')
end
add('cg_sideslip_estimate_rad', 'rad')
for _, axis in ipairs({'x', 'y', 'z'}) do
  add('tyre_force_sum_body_' .. axis .. '_N', 'N')
end
for _, axis in ipairs({'x', 'y', 'z'}) do
  add('tyre_moment_sum_cg_estimate_body_' .. axis .. '_Nm', 'N*m')
end

return channels
