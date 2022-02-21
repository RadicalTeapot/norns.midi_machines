local ui = require 'ui'

local Machine = {
    __id = 0,
    next = nil,
    previous = nil,

    max_sequence_length = 1,
    clock_count = 0,
    dials = {},
    position = 1,
    label = '',
    metro = nil,
    previous_value = 0,
    slew_count = 1,
    slew_counter = 1,
    send_midi_cc = nil,
    playback_icon = nil
}
Machine.__index = Machine

Machine.Params_mt = {
    __index=function(table, index)
        table[index] = {
            id=table.__id.."_"..index,
            get=function() return params:get(table[index].id) end,
            set=function(v) params:set(table[index].id, v) end,
            delta=function(d) params:delta(table[index].id, d) end,
            toString=function() return params:string(table[index].id) end,
            set_action=function(action) params:set_action(table[index].id, action) end,
        }
        return table[index]
    end
}

function Machine.new(id, send_midi_cc, label, default_values, max_sequence_length, max_clock_div)
    local self = setmetatable({}, Machine)
    self.params = setmetatable({__id=id}, Machine.Params_mt)

    self.label = label
    self.max_sequence_length = max_sequence_length
    self.dials = {
        steps=ui.Dial.new(55, 28, 22, 8, 1, self.max_sequence_length, 1, 1, {self.max_sequence_length * 0.5}),
        knob=ui.Dial.new(100, 28, 22, 50, 0, 100, 1, 50, {50})
    }
    self.playback_icon = ui.PlaybackIcon.new(0, 10, 5, 1)
    self.playback_icon.active = true
    self.send_midi_cc = send_midi_cc or function(machine, value) end

    self.metro = metro.init()
    self.metro.event = function() self:send_slewed_value() end

    self:add_params(default_values, max_clock_div)
    self:add_hidden_params()
    self:init_sequence()

    self.previous_value = self.params[self.position].get()

    self.params.knob.get_orig = self.params.knob.get
    self.params.knob.get = function() return self:__get_linexp_value(self.params.knob.get_orig()) end

    return self
end

function Machine:add_params(default_values, max_clock_div)
    params:add_group(self.label, 11)

    params:add_binary(self.params.active.id, "Active", "toggle", 1)
    params:set_action(self.params.active.id, function()
        self:set_dials_active(self.params.active.get() == 1)
    end)
    params:add_binary(self.params.running.id, "Running", "toggle", 1)
    params:set_action(self.params.running.id, function()
        self.playback_icon.status = (1 - self.params.running.get()) * 2 + 1
        self.playback_icon.active = self.params.running.get() == 1
    end)

    params:add_number(self.params.clock_div.id, "Clock div", 1, max_clock_div, default_values.clock_div)

    params:add_number(self.params.steps.id, "Steps", 1, self.max_sequence_length, default_values.steps)
    params:set_action(self.params.steps.id, function() self:refresh_dials_values(true, false) end)
    params:add_number(self.params.knob.id, "Knob", 0, 100, default_values.knob)
    params:set_action(self.params.knob.id, function() self:refresh_dials_values(false, true) end)

    params:add_number(self.params.default.id, 'Default', 0, 127, default_values.default)
    params:add_number(self.params.range_min.id, "Range min", 0, 127, default_values.range_min)
    params:add_number(self.params.range_max.id, "Range max", 0, 127, default_values.range_max)

    params:add_number(self.params.channel.id, "Channel", 1, 16, default_values.channel)
    params:add_number(self.params.CC.id, "CC", 0, 127, default_values.CC)

    params:add_control(self.params.slew_time.id, "Slew time", controlspec.new(0.05, 10, 'exp', 0.05, default_values.slew_time, 's'))

    self.dials.steps:set_value(default_values.steps)
    self.dials.knob:set_value(self:__get_linexp_value(default_values.knob))
end

function Machine:add_hidden_params()
    for i=1,self.max_sequence_length do
        params:add_number(self.params[i].id, '', 0, 1, 0)
        params:hide(self.params[i].id)
    end
end

function Machine:refresh_dials_values(refresh_steps, refresh_knob)
    if refresh_steps then
        local new_value = self.params.steps.get()
        self.dials.steps:set_value(new_value)
        self.dials.steps:set_marker_position(1, new_value)
    end

    if refresh_knob then
        local new_value = self.params.knob.get()
        self.dials.knob:set_value(new_value)
        self.dials.knob:set_marker_position(1, new_value)
    end
end

function Machine:init_sequence()
    for i=1,self.max_sequence_length do
        self.params[i].set(math.random())
    end
end

function Machine:randomize_current_step()
    self.params[self.position].set(math.random())
end

function Machine:toggle_running()
    self.params.running.set(1 - self.params.running.get())
end

function Machine:remap_value(value)
    local min = math.min(self.params.range_min.get(), self.params.range_max.get())
    local max = math.max(self.params.range_min.get(), self.params.range_max.get())
    return math.floor(value * math.abs(max - min) + math.min(min, max) + 0.5)
end

function Machine:get_next_value()
    if self.params.active.get() == 1 then
        return self:update_sequence_and_get_value()
    else
        return self:send_midi_cc(self.params.default.get())
    end
end

function Machine:update_sequence_and_get_value()
    if self.params.running.get() == 1 then
        if self.clock_count >= self.params.clock_div.get() then
            self.previous_value = self.params[self.position].get()
            self:mutate_sequence()
            self:move_to_next_position()
            self.clock_count = 1

            self.slew_count = math.floor(self.params.slew_time.get() / 0.05)
            self.slew_counter = 0
            self.metro:start(0.05, self.slew_count)
            self:send_slewed_value()
        else
            self.clock_count = self.clock_count + 1
        end
    end
end

function Machine:send_slewed_value()
    local value = util.linlin(1, self.slew_count, self.previous_value, self.params[self.position].get(), self.slew_counter)
    self:send_midi_cc(self:remap_value(value))
    self.slew_counter = self.slew_counter + 1
end

function Machine:mutate_sequence()
    local knob = self.params.knob.get()
    local steps = self.params.steps.get()
    if knob < 50 then
        local probability = 50 - knob
        if math.random(50) <= probability then
            self:randomize_current_step()
        end
    elseif knob > 50 then
        local probability = knob - 50
        if math.random(50) <= probability then
            -- Find other position to swap value with
            local other_position = self.position
            while other_position == self.position do
                other_position = math.random(steps)
            end

            -- Swap value with other position
            local tmp = self.params[other_position].get()
            self.params[other_position].set(self.params[self.position].get())
            self.params[self.position].set(tmp)
        end
    end
end

function Machine:move_to_next_position()
    self.position = util.wrap(self.position + 1, 1, self.params.steps.get())
end

function Machine:redraw()
    local active = self.params.active.get() == 1
    if active then
        self:draw_dials()
        self.playback_icon:redraw()
    end
    self:draw_title(0, 5)
    if active then
        self:draw_range(0, 25, 10, alt)
        self:draw_sequence(60, 5, 5)
    else
        screen.level(15)
        screen.move(60, 5)
        screen.text("DISABLED")
        screen.level(1)
        screen.move(0, 25)
        screen.text('Default value:')
        screen.level(15)
        screen.move(0,35)
        screen.text(self.params.default.toString())
    end
end

function Machine:draw_sequence(x, y, scale)
    local index = self.position
    local steps = self.params.steps.get()
    local max_level = 15
    if not self.params.active.get() == 1 then max_level = 7 end
    for i=0,math.min(steps - 1, 7) do
        index = util.wrap(self.position + i, 1, steps)
        screen.level(math.floor(self.params[index].get() * max_level + 1))
        screen.rect(x + i * 8, y - scale, scale, scale)
        screen.fill()
    end
end

function Machine:draw_dials()
    self.dials.steps:redraw()
    self.dials.knob:redraw()
    screen.move(53, 20)
    screen.text('Steps')
    screen.move(100, 20)
    screen.text('Knob')
end

function Machine:draw_range(x, y, spacing, active)
    screen.level(1)
    screen.move(x, y)
    screen.text("Min")
    screen.move(x, y + 2 * spacing)
    screen.text("Max")
    if active then screen.level(15) else screen.level(1) end
    screen.move(x, y + spacing)
    screen.text(self.params.range_min.toString())
    screen.move(x, y + 3 * spacing)
    screen.text(self.params.range_max.toString())
end

function Machine:draw_title(x, y)
    screen.level(1)
    screen.move(x, y)
    screen.text(string.upper(self.label))
end

function Machine:set_dials_active(state)
    self.dials.steps.active = state
    self.dials.knob.active = state
end

function Machine:__get_linexp_value(x)
    x = x - 50
    if (x > 0) then
        x = util.linexp(0, 50, 1, 51, x) - 1
    else
        x = util.linexp(-50, 0, -51, -1, x) + 1
    end
    return util.round(x+50, 0.5)
end

function Machine:delete()
    self.__previous.__next = self.__next
    self.__next.__previous = self.__previous
    metro.free(self.metro.props.id)
end

local MachineFactory = {
    __instance_count = 0,
    __first = nil,
    __last = nil,

    max_step_count = 16,
}

function MachineFactory:new_machine(send_midi_cc, label, default_values, max_sequence_length, max_clock_div)
    label = label or ("Machine "..(self.__instance_count+1))
    default_values = default_values or {}
    default_values = {
        steps = default_values.steps or 8,
        knob = default_values.knob or 50,
        clock_div = default_values.clock_div or 1,
        default = default_values.default or 64,
        range_min = default_values.range_min or 30,
        range_max = default_values.range_max or 100,
        channel = default_values.channel or 1,
        CC = default_values.CC or 0,
        slew_time = default_values.slew_time or 0.25,
    }
    max_sequence_length = max_sequence_length or 16
    max_clock_div = max_clock_div or 64
    local machine = Machine.new(self.__instance_count + 1, send_midi_cc, label, default_values, max_sequence_length, max_clock_div)

    machine.previous = self.__last
    machine.next = self.__first
    if self.__last ~= nil then
        self.__last.next = machine
    end
    if self.__first == nil then
        self.__first = machine
    else
        self.__first.previous = machine
    end
    self.__last = machine

    self.__instance_count = self.__instance_count + 1

    return machine
end

return MachineFactory
