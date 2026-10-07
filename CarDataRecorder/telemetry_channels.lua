-- Shared sender/recorder contract. This file contains column definitions only;
-- it is not a telemetry payload. Keep the recorder copy identical.
local channels = {eventName = 'VehicleTelemetry', fields = {}, byName = {}}
channels.bodyFrame = 'X_forward_Y_left_Z_up'
channels.anglePositive = 'counterclockwise_viewed_from_above'
channels.baseColumns = {
  {'time_s', 's'}, {'speed_kmh', 'km/h'}, {'steering_angle_deg', 'deg'},
  {'throttle_pct', '%'}, {'brake_pct', '%'}, {'clutch_pct', '%'},
  -- World position is a fixed track frame, not the rotating vehicle frame.
  {'position_ac_world_x_m', 'm'}, {'position_ac_world_y_m', 'm'}, {'position_ac_world_z_m', 'm'},
  {'acceleration_body_x_g', 'g'}, {'acceleration_body_y_g', 'g'},
  {'acceleration_body_z_g', 'g'}
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
  -- Wheel contact directions: forward rolling direction, left tangent, road normal.
  -- These preserve the original quantities while normalizing their signs.
  add(wheel .. '_tyre_force_longitudinal_N', 'N')
  add(wheel .. '_tyre_force_lateral_N', 'N')
  add(wheel .. '_tyre_normal_load_N', 'N')
  -- User body basis: X=forward, Y=left, Z=up (right-handed).
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
