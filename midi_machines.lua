-- Midi machines
-- Turing machine based
-- midi sending machines

-- TODO
-- Currently an inactive machine sends signals out every beat whereas a not running machine doesn't send it at all,
-- rename active to "use default" or something similar (and send value only when it changes ?)
-- Figure out a way to clean params when deleting a machine
-- Figure out a way to work with presets (currently the number of created machines is not saved, neither is their id)
-- For the above, use a json / text file describing the machines and initialy only have a param loading the file

MachineFactory = include('lib/machine')
current_machine = nil
alt = false
midi_devices = {}
midi_device = nil
machines = {}

function init()
    build_midi_device_list()

    params:add_binary("running", "Running", "toggle", 1)

    params:add_option("midi_device", "Devices", midi_devices, 1)
    params:set_action("midi_device", function()
        local index = params:get("midi_device")
        print("Connecting to midi device "..midi_devices[index])
        midi_device = midi.connect(index)
    end)

    function send_midi_cc(machine, value)
        -- print("Sending values on "..machine.params.channel.get()..":"..machine.params.CC.get())
        midi_device:cc(machine.params.CC.get(), value, machine.params.channel.get())
    end
    machines = {}
    machines[1] = MachineFactory:new_machine(send_midi_cc, nil, {CC=0})
    machines[2] = MachineFactory:new_machine(send_midi_cc, nil, {CC=1})
    current_machine = machines[1]
    -- for i=1,3 do
    --     MachineFactory:new_machine()
    -- end

    screen.line_width(1)
    screen.aa(1)

    norns.enc.sens(1, 12)

    clock.run(update)
end

function enc(index, delta)
    if index==1 then
        if delta < 0 and current_machine.previous then
            current_machine = current_machine.previous
        elseif delta > 0 and current_machine.next then
            current_machine = current_machine.next
        end
    end

    if current_machine.params.active.get() then
        if not alt then
            if index==2 then
                current_machine.params.steps.delta(delta)
            elseif index==3 then
                current_machine.params.knob.delta(delta)
            end
        else
            if index==2 then
                current_machine.params.range_min.delta(delta)
            elseif index==3 then
                current_machine.params.range_max.delta(delta)
            end
        end
    else
        if index==2 then
            current_machine.params.range_min.delta(delta)
        elseif index==3 then
            current_machine.params.range_max.delta(delta)
        end
    end

    redraw()
end

function key(index, state)
    if current_machine.params.active.get() then
        if index == 1 then
            alt = state == 1
            current_machine:set_dials_active(not alt)
        elseif index == 2 and state == 1 then
            if alt then current_machine:move_to_next_position()
            else current_machine:toggle_running() end
        elseif index == 3 and state == 1 then
            if alt then current_machine:randomize_current_step()
            else current_machine:init_sequence() end
        end
        redraw()
    end
end

function update()
    while true do
        clock.sync(1)
        if params:get("running") == 1 then
            for i=1,#machines do machines[i]:get_next_value() end
            redraw()
        end
    end
end

function send_midi_CC(machine, value)
end

function redraw()
    screen.clear()
    screen.fill()
    current_machine:redraw()
    screen.update()
end

function build_midi_device_list()
  midi_devices = {}
  for i = 1,#midi.vports do
    local long_name = midi.vports[i].name
    local short_name = string.len(long_name) > 15 and util.acronym(long_name) or long_name
    table.insert(midi_devices,i..": "..short_name)
    -- Auto-connect to first available device
    if i == 1 then midi_device = midi.connect(i) end
  end
end

function r()
    norns.script.load(norns.state.script)
end
