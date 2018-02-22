local ngx_now      = ngx.now
local ngx_log      = ngx.log
local ERR          = ngx.ERR
local INFO         = ngx.INFO
local NOTICE       = ngx.NOTICE
local DEBUG        = ngx.DEBUG
local re_match     = ngx.re.match
local tbl_insert   = table.insert
local tbl_concat   = table.concat


local exec_socket  = require('resty.exec.socket') 

function interp(s, tab)
    return (s:gsub('($%b{})', function(w) return tab[w:sub(3, -2)] or w end))
end

-- Auth proxy Public Interface
local Cloudscale = {}


function Cloudscale:new(config)
    if not config['shm'] or not ngx.shared[config['shm']] then
        ngx_log(ERR, 'Cloudscale: "shm" config option must be the name of a configured ngx shared dict!')
        return nil
    end

    if not config['header'] then
        ngx_log(ERR, 'Cloudscale: "header" config option must be a string!')
        return nil
    end

    if not config['header_regex'] then
        ngx_log(ERR, 'Cloudscale: "header_regex" config option must be a string!')
        return nil
    end

    if not config['data'] then
        ngx_log(ERR, 'Cloudscale: "data" config option must be a table!')
        return nil
    end

    if not config['sockexec_path'] then
        ngx_log(ERR, 'Cloudscale: "sockexec_path" config option must be a path to a running sockexec socket!')
        return nil
    end

    local o = {
        data          = {},
        instances     = ngx.shared[config['shm']],
        command       = config['command'] or {},
        header        = config['header'],
        header_regex  = config['header_regex'], 
        sockexec_path = config['sockexec_path'],
        timeout       = config['timeout'] or 7200     -- Processes will run for 7200s by default
    }

    -- Uniquely number each instance on start
    local count = config['id_start'] or 0
    for k, v in pairs(config['data']) do
        v['id'] = count
        o.data[k] = v
        count = count + 1
    end

    local self = setmetatable(o, {__index = Cloudscale})

    ngx_log(INFO, 'Cloudscale: Loading complete...')

    return self
end


function Cloudscale:authenticate(stdin)
    local instances     = self['instances']
    local data          = self['data']
    local command       = self['command']
    local header        = self['header']
    local header_regex  = self['header_regex']
    local sockexec_path = self['sockexec_path']

    local headers = ngx.req.get_headers()

    local target_header = headers[header]

    if not target_header then
        ngx_log(ERR, 'Cloudscale: Header ', header, ' not found in request')
        return nil, "no header found"
    end

    -- Regex out value of given header. Return nil if request 
    -- does not contain valid header, or matching regex
    local regex_output = ngx.re.match(target_header, header_regex, 'jo')
    if not regex_output then
        ngx_log(ERR, 'Cloudscale: Unable to find match for ', header_regex, ' in header ', header)
        return nil, "no regex match"
    end

    -- Value is first capture group
    local regex_value = regex_output[1]

    -- Check if we have a configuration value locally for this header value
    local data_value = data[regex_value]

    if not data_value then
        ngx_log(ERR, 'Cloudscale: Unable to find configuration for value ', regex_value, ' in provided data')
        return nil, "no config"
    end

    -- Lock process by attempting to add the current time to the shared dict as its name
    local ok, err = instances:safe_add(regex_value, ngx_now())

    -- Process did not exist so lets spawn it
    if ok then

        process = exec_socket:new({ timeout = self['timeout'] })
        local ok, err = process:connect(sockexec_path)

        if not ok then
            ngx_log(ERR, 'Cloudscale: Unable to connect to sockexec on path ', sockexec_path, ': ', err)
            instances:delete(regex_value)
            return nil, "sockexec error"
        end

        -- Interpolate command values
        -- Add header value to interp
        data_value['header_value'] = regex_value
        for int, arg in ipairs(command) do
            command[int] = interp(arg, data_value)
        end
        
        ngx_log(INFO, 'Cloudscale: Spawning new process for value ', regex_value, ' with command line ', tbl_concat(command, ' '))

        process:send_args(command)

        local send = ''
        if stdin then
            send = stdin
        elseif data_value['stdin'] then
            send = data_value['stdin']
        end

        process:send(send) -- Send any stdin and close
        process:send_close()
    else
        if err and err ~= 'exists' then
            ngx_log(ERR, 'Cloudscale: Error looking up instance in shm for value ', regex_value, ': ', err)
            return nil, "shm error"
        end
    end
    -- Update LRU value
    local ok, err = instances:replace(regex_value, ngx_now())

    if not ok then
        ngx_log(ERR, 'Cloudscale: Error updating instance LRU for value ', regex_value, ': ', err)
        return nil, "lru error"
    end

    ngx.var.cloudscale_id = data_value['id'] 
    return true
end

return Cloudscale
