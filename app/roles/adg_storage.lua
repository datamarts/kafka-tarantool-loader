-- Copyright 2021 Kafka-Tarantool-Loader
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local cartridge = require("cartridge")
local prometheus = require("metrics.plugins.prometheus")
local ddl = require("ddl")
local schema_utils = require("app.utils.schema_utils")
local mutex_map = require("app.utils.mutex_map")
local etl_config = require("app.etl.config.etl_config")
local query_debug_config = require("app.utils.query_debug_config")
local query_dbg_opts = nil
local yaml = require("yaml")
local json = require("json")
local log = require("log")
local clock = require("clock")
local errors = require("errors")
local checks = require("checks")
local fiber = require("fiber")
local garbage_fiber = nil
local validate_utils = require("app.utils.validate_utils")
local dtm_digest_utils = require("app.utils.dtm_digest_utils")
local fun = require("fun")
local set = require("app.entities.set")
local metrics = require("app.metrics.metrics_storage")
local role_name = "app.roles.adg_storage"
local moonwalker = require("moonwalker")
local sql_insert = require("app.utils.sql_insert")
local success_repository = require("app.messages.success_repository")
local error_repository = require("app.messages.error_repository")

_G.insert_tuples = nil
_G.drop_space = nil
_G.truncate_space = nil
_G.drop_spaces = nil
_G.drop_spaces_with_prefix = nil
_G.storage_drop_all = nil
_G.storage_space_count = nil
_G.storage_space_len = nil
_G.get_metric = nil
_G.prep_sql = nil
_G.execute_sql = nil
_G.set_schema_ddl = nil
_G.get_storage_ddl = nil
_G.get_space_format = nil
_G.check_table_for_delta_fields = nil
_G.check_tables_for_delta = nil
_G.transfer_stage_data_to_scd_table = nil
_G.reverse_history_in_scd_table = nil
_G.delete_data_from_scd_table_sql = nil
_G.get_scd_table_checksum = nil
_G.table_mutex_map = nil
_G.index_create = nil
_G.index_drop = nil
_G.add_columns = nil
_G.drop_columns = nil
_G.transform_query_to_tuple = nil
_G.remove_spaces_from_bucket_id_cache = nil

local err_storage = errors.new_class("Storage error")

local prepared_statements = {}

local function insert_tuples(tuples, is_record_type)
    checks("table", "?boolean")
    is_record_type = is_record_type or false
    box.begin()
    local res, err = err_storage:pcall(function()
        local rows_inserted = 0
        for space_name, by_space in pairs(tuples) do
            for _, tuple in ipairs(by_space) do
                local space = box.space[space_name]
                if space == nil then
                    return nil, err_storage:new("No such space: %s", space_name)
                end
                if is_record_type then
                    local t, e = space:frommap(tuple)
                    if t == nil then
                        return nil, e
                    end
                    space:put(t)
                else
                    space:put(tuple)
                end
                rows_inserted = rows_inserted + 1
            end
        end
        return rows_inserted
    end)
    box.commit()
    if res == nil then
        return nil, err
    end

    return res
end

local function prep_sql(query)
    local prep = box.prepare(query)
    prepared_statements[query] = prep
end

local function execute_sql(query, params)
    checks("string", "?table")

    -- luacheck: ignore res err
    local res, err = nil, nil

    local start_time = clock.time()

    local prep = prepared_statements[query]
    if prep ~= nil then
        if params == nil then
            res, err = err_storage:pcall(prep.execute, prep)
        else
            res, err = err_storage:pcall(prep.execute, prep, params)
        end
    else
        if params == nil then
            res, err = err_storage:pcall(box.execute, query)
        else
            res, err = err_storage:pcall(box.execute, query, params)
        end
    end

    if query_dbg_opts:is_query_debug_enable() then
        local req_time = (clock.time() - start_time) * 1000
        log.info("query: %s, params: %s, execution time (ms): %f", query, json.encode(params), req_time)
    end

    return res, err
end

---drop_space - function to drop space
---@param space_name string - space name to drop.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function drop_space(space_name)
    checks("string")
    return err_storage:pcall(function()
        if not string.startswith(space_name, "_") then
            box.space[space_name]:drop()
            box.space["_ddl_sharding_key"]:delete(space_name)
        end
        return true, nil
    end)
end

---truncate_space - function to truncate space
---@param space_name string - space name to truncate.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function truncate_space(space_name)
    checks("string")
    return err_storage:pcall(function()
        if not string.startswith(space_name, "_") then
            box.space[space_name]:truncate()
        end
        return true, nil
    end)
end

---drop_spaces - function to drop spaces
---@param spaces table - list of tables to drop
---@return boolean|table - dropped_spaces,nil if dropped | dropped_spaces,error - otherwise.
local function drop_spaces(spaces)
    checks("table")
    local dropped_spaces = {}
    return err_storage:pcall(function()
        for _, v in ipairs(spaces) do
            if not string.startswith(v, "_") then
                if box.space[v] ~= nil then
                    box.space[v]:drop()
                    table.insert(dropped_spaces, v)
                end
                box.space["_ddl_sharding_key"]:delete(v)
            end
        end
        return dropped_spaces, nil
    end)
end

local function drop_spaces_with_prefix(prefix)
    checks("string")
    local dropped_spaces = {}
    return err_storage:pcall(function()
        for _, v in box.space._space:pairs({}) do
            local space_name = v[3]
            if string.startswith(space_name, prefix) then
                if box.space[space_name] ~= nil then
                    box.space[space_name]:drop()
                    table.insert(dropped_spaces, space_name)
                end
                box.space["_ddl_sharding_key"]:delete(space_name)
            end
        end
        return dropped_spaces, nil
    end)
end

local function storage_drop_all()
    return err_storage:pcall(function()
        for key, space in pairs(box.space) do
            if not string.startswith(space.name, "_") and type(key) == "string" then
                space:drop()
            end
        end

        return true
    end)
end

-- only for vinyl tests
local function storage_space_count(space_name)
    checks("string")

    return box.space[space_name]:count()
end
-- only for vinyl tests

local function storage_space_len(space_name)
    checks("string")

    return box.space[space_name]:len()
end

local function get_metric()
    return metrics.export(role_name)
end

---get_storage_ddl
local function get_storage_ddl()
    return schema_utils.get_current_schema_ddl()
end

local function set_schema_ddl()
    schema_utils.init_schema_ddl()
    return schema_utils.set_schema(schema_utils.get_schema_ddl())
end

---get_space_format
--- Method returns array of `space_name` fields.
---@param space_name string - Name of space to get fields array.
---@return table,string|nil
local function get_space_format(space_name)
    checks("string")
    if get_storage_ddl().spaces[space_name] == nil then
        return nil, error_repository.get_error_code("STORAGE_001", { space = space_name })
    end

    return fun.map(function(x)
        return x.name
    end, get_storage_ddl().spaces[space_name].format):totable(),
        nil
end

local function get_index_from_space_by_name(space_name, index_name)
    checks("string", "string")
    if box.space[space_name] == nil then
        log.error(error_repository.get_error_code("STORAGE_001", { space = space_name }))
        return nil
    end

    for _, index in ipairs(box.space[space_name].index) do
        if index.name == index_name then
            return index
        end
    end
    return nil
end

---check_table_for_delta_fields
---Method, that checks:
--- 1) is space exists
--- 2) is all required fields exists in space
--- 3) is index[0] exists and UNIQUE
--- 4) is etl_config.get_date_field_start_nm() last field in PK in actual and history tables
---@param space_name string - Name of space to check.
---@param table_type string - Flag, that marks is space a historical space, stage space or actual_space.
---@return boolean,string|nil
local function check_table_for_delta_fields(space_name, table_type)
    checks("string", "string")

    -- Check is space exists
    local space_fields, err_ddl = get_space_format(space_name)

    if err_ddl ~= nil then
        return false, err_ddl
    end

    -- Check is all required fields exists in space
    -- luacheck: ignore required_fields
    local required_fields = nil
    if table_type == "history" then
        required_fields = set.Set({
            etl_config.get_date_field_end_nm(),
            etl_config.get_date_field_start_nm(),
            etl_config.get_date_field_op_nm(),
        })
    elseif table_type == "actual" then
        required_fields = set.Set({ etl_config.get_date_field_start_nm(), etl_config.get_date_field_op_nm() })
    else
        required_fields = set.Set({ etl_config.get_date_field_op_nm() })
    end

    -- luacheck: ignore v
    local is_required_fields_ok = fun.all(function(k, v)
        for _, f in ipairs(space_fields) do
            if f == k then
                required_fields[k] = nil
                return true
            end
        end
        return false
    end, required_fields)

    if not is_required_fields_ok then
        local err_req_fields = ""
        for k, v in pairs(required_fields) do
            err_req_fields = err_req_fields .. k .. " "
        end
        return false, error_repository.get_error_code("STORAGE_002", { space = space_name, fields = err_req_fields })
    end

    --Check is index[0] exists and UNIQUE
    local primary_key = box.space[space_name].index[0]

    if primary_key == nil then
        return false, "ERROR: Could not find PK on space" .. space_name --TODO err repo
    end

    if not primary_key.unique then
        return false, "ERROR: Primary key must be unique in" .. space_name --TODO err repo
    end

    -- Check is etl_config.get_date_field_start_nm() last field in PK
    local primary_key_fields = fun.map(function(x)
        return space_fields[x.fieldno]
    end, primary_key.parts):totable()
    if primary_key_fields[#primary_key_fields] ~= etl_config.get_date_field_start_nm() and table_type ~= "stage" then
        return false,
            error_repository.get_error_code(
                "STORAGE_DELTA_TRANSFER_001",
                { key_fields = primary_key_fields, space = space_name }
            )
    end
    return true, nil
end

---check_tables_for_delta
---Method, that checks field compatibility between actual and historical tables.
---@param actual_data_table_name string - Name of the table, that contains actual data for delta processing.
---@param historical_data_table_name string - Name of the table, that contains historical data for delta processing.
---@return boolean,string|nil
local function check_tables_for_delta(actual_data_table_name, historical_data_table_name)
    checks("string", "string")
    -- Check if space exists
    local actual_data_fields, actual_err_ddl = get_space_format(actual_data_table_name)

    if actual_err_ddl ~= nil then
        return false, actual_err_ddl
    end

    local hist_data_fields, hist_err_ddl = get_space_format(historical_data_table_name)

    if hist_err_ddl ~= nil then
        return false, hist_err_ddl
    end

    local hist_data_fields_set = set.Set(hist_data_fields)

    local all_fields_ok = fun.all(function(elem)
        return hist_data_fields_set[elem] or false
    end, actual_data_fields)

    if not all_fields_ok then
        return all_fields_ok,
            error_repository.get_error_code(
                "STORAGE_DELTA_TRANSFER_002",
                { actual_fields = actual_data_fields, hist_fields = hist_data_fields }
            )
    end

    local actual_data_pk_fields = fun.map(function(x)
        return actual_data_fields[x.fieldno]
    end, box.space[actual_data_table_name].index[0].parts):totable()
    local hist_data_pk_fields = fun.map(function(x)
        return hist_data_fields[x.fieldno]
    end, box.space[historical_data_table_name].index[0].parts):totable()

    local hist_data_pk_fields_set = set.Set(hist_data_pk_fields)

    local all_pk_fields_ok = fun.all(function(elem)
        return hist_data_pk_fields_set[elem] or false
    end, actual_data_pk_fields)

    if all_pk_fields_ok then
        return all_pk_fields_ok, nil
    else
        return all_fields_ok,
            error_repository.get_error_code(
                "STORAGE_DELTA_TRANSFER_002",
                { actual_data_pk_fields = actual_data_pk_fields, hist_data_pk_fields = hist_data_pk_fields }
            )
    end
end

---key_from_tuple
---@param tuple table|userdata - tarantool tuple or lua table to extract key
---@param key_parts table - positions of key elements in tuple
---@return table|userdata - value of key elements in tuple
local function key_from_tuple(tuple, key_parts)
    local key = {}
    for _, part in ipairs(key_parts) do
        table.insert(key, tuple[part] or box.NULL)
    end
    return key
end

---transfer_stage_data_to_scd_table
---@param stage_data_table_name string - Name of the table, that contains hot data for scd processing.
---@param actual_data_table_name string - Name of the table, that contains actual data for scd processing.
---@param historical_data_table_name string - Name of the table, that contains history data for scd processing.
---@param delta_number number - Number, that marks new version of data.
---@return boolean,string|nil
local function transfer_stage_data_to_scd_table(
    stage_data_table_name,
    actual_data_table_name,
    historical_data_table_name,
    delta_number
)
    checks("string", "string", "string", "number")

    local is_stage_table_ok, err_stage = check_table_for_delta_fields(stage_data_table_name, "stage")
    local is_data_table_ok, err_data = check_table_for_delta_fields(actual_data_table_name, "actual")
    local is_historical_table_ok, err_hist = check_table_for_delta_fields(historical_data_table_name, "history")

    if not is_stage_table_ok then
        return false, err_stage
    end

    if not is_data_table_ok then
        return false, err_data
    end

    if not is_historical_table_ok then
        return false, err_hist
    end

    local is_tables_meta_ok, tables_meta_err = check_tables_for_delta(
        actual_data_table_name,
        historical_data_table_name
    )

    if not is_tables_meta_ok then
        return false, tables_meta_err
    end

    local is_stage_table_meta_ok, stage_table_meta_err = check_tables_for_delta(
        stage_data_table_name,
        actual_data_table_name
    )

    if not is_stage_table_meta_ok then
        return false, stage_table_meta_err
    end

    --Get stage primary key
    local stage_data_pk = fun.map(function(x)
        return x.fieldno
    end, box.space[stage_data_table_name].index[0].parts):totable()
    local actual_data_pk = fun.map(function(x)
        return x.fieldno
    end, box.space[actual_data_table_name].index[0].parts):totable()

    local stage_data_table = box.space[stage_data_table_name]
    local actual_data_table = box.space[actual_data_table_name]
    local hist_data_table = box.space[historical_data_table_name]

    local function transfer_function(stage_tuple)
        box.begin()
        local actual_tuples = actual_data_table:select(key_from_tuple(stage_tuple, stage_data_pk))
        for _, actual_tuple in ipairs(actual_tuples) do
            if actual_tuple[etl_config.get_date_field_start_nm()] < delta_number then
                local actual_tuple_map = actual_tuple:tomap({ names_only = true })
                actual_tuple_map[etl_config.get_date_field_end_nm()] = delta_number - 1
                actual_tuple_map[etl_config.get_date_field_op_nm()] = stage_tuple[etl_config.get_date_field_op_nm()]
                hist_data_table:put(hist_data_table:frommap(actual_tuple_map))
                actual_data_table:delete(key_from_tuple(actual_tuple, actual_data_pk))
            end
        end
        if stage_tuple[etl_config.get_date_field_op_nm()] ~= 1 then
            local stage_tuple_map = stage_tuple:tomap({ names_only = true })
            stage_tuple_map[etl_config.get_date_field_start_nm()] = delta_number
            actual_data_table:put(actual_data_table:frommap(stage_tuple_map))
        end
        stage_data_table:delete(key_from_tuple(stage_tuple, stage_data_pk))
        box.commit()
    end

    -- create mutex for each space than blocking concurrency write operation in special space
    -- instead of blocking all write operations
    table_mutex_map:lock(stage_data_table)
    table_mutex_map:lock(actual_data_table)
    table_mutex_map:lock(hist_data_table)

    local _, err = err_storage:pcall(function()
        moonwalker({
            space = stage_data_table,
            actor = transfer_function,
            pause = etl_config.get_transfer_pause_rows_cnt() or 100,
            txn = false,
        })
        return true, nil
    end)

    -- free mutex for each space
    table_mutex_map:unlock(stage_data_table)
    table_mutex_map:unlock(actual_data_table)
    table_mutex_map:unlock(hist_data_table)

    if err ~= nil then
        log.error(err.trace)
        return nil, error_repository.get_error_code("STORAGE_003", { error = err })
    end

    return true, nil
end

local function reverse_history_in_scd_table(
    stage_data_table_name,
    actual_data_table_name,
    historical_data_table_name,
    delta_number,
    batch_size
)
    checks("string", "string", "string", "number", "?number")

    local is_stage_table_ok, err_stage = check_table_for_delta_fields(stage_data_table_name, "stage")
    local is_data_table_ok, err_data = check_table_for_delta_fields(actual_data_table_name, "actual")
    local is_historical_table_ok, err_hist = check_table_for_delta_fields(historical_data_table_name, "history")

    if not is_stage_table_ok then
        log.error(err_stage)
        return false, err_stage
    end

    if not is_data_table_ok then
        log.error(err_data)
        return false, err_data
    end

    if not is_historical_table_ok then
        log.error(err_hist)
        return false, err_hist
    end

    local is_tables_meta_ok, tables_meta_err = check_tables_for_delta(
        actual_data_table_name,
        historical_data_table_name
    )

    if not is_tables_meta_ok then
        log.error(tables_meta_err)
        return false, tables_meta_err
    end

    local is_stage_table_meta_ok, stage_table_meta_err = check_tables_for_delta(
        stage_data_table_name,
        actual_data_table_name
    )

    if not is_stage_table_meta_ok then
        log.error(stage_table_meta_err)
        return false, stage_table_meta_err
    end

    --Get primary keys
    local actual_data_pk = fun.map(function(x)
        return x.fieldno
    end, box.space[actual_data_table_name].index[0].parts):totable()
    local hist_data_pk = fun.map(function(x)
        return x.fieldno
    end, box.space[historical_data_table_name].index[0].parts):totable()

    --clear staging
    local stage_data_table = box.space[stage_data_table_name]
    local _, err_clear_stg = err_storage:pcall(function()
        stage_data_table:truncate()
    end)
    if err_clear_stg ~= nil then
        log.error(err_clear_stg)
        return nil, error_repository.get_error_code("STORAGE_003", { error = err_clear_stg })
    end

    --clear actual
    local actual_data_table = box.space[actual_data_table_name]
    local hist_data_table = box.space[historical_data_table_name]

    local _, err_clear_stg_act = err_storage:pcall(function()
        local sys_to_index = get_index_from_space_by_name(
            actual_data_table_name,
            etl_config.get_date_field_start_index_nm()
        )
        if sys_to_index == nil then
            actual_data_table:pairs():each(function(actual_tuple)
                if actual_tuple[etl_config.get_date_field_start_nm()] == delta_number then
                    actual_data_table:delete(key_from_tuple(actual_tuple, actual_data_pk))
                end
            end)
        else
            sys_to_index:pairs(delta_number):each(function(actual_tuple)
                actual_data_table:delete(key_from_tuple(actual_tuple, actual_data_pk))
            end)
        end
        return true, nil
    end)
    if err_clear_stg_act ~= nil then
        log.error(err_clear_stg_act)
        return nil, error_repository.get_error_code("STORAGE_003", { error = err_clear_stg_act })
    end

    --clear history table
    local move_hist_tuple_function = function(history_data_tbl, actual_data_tbl, hist_tuple)
        local hist_tuple_map = hist_tuple:tomap({ names_only = true })
        hist_tuple_map[etl_config.get_date_field_end_nm()] = nil
        hist_tuple_map[etl_config.get_date_field_op_nm()] = 0
        history_data_tbl:delete(key_from_tuple(hist_tuple, hist_data_pk))
        actual_data_tbl:put(actual_data_tbl:frommap(hist_tuple_map))
    end

    local err_clear_hist
    if batch_size == nil then
        box.begin()
        _, err_clear_hist = err_storage:pcall(function()
            local sys_from_index = get_index_from_space_by_name(
                historical_data_table_name,
                etl_config.get_date_field_end_index_nm()
            )
            if sys_from_index == nil then
                hist_data_table:pairs():each(function(hist_tuple)
                    if hist_tuple[etl_config.get_date_field_end_nm()] == delta_number - 1 then
                        move_hist_tuple_function(hist_data_table, actual_data_table, hist_tuple)
                    end
                end)
            else
                sys_from_index:pairs({ delta_number - 1 }):each(function(hist_tuple)
                    move_hist_tuple_function(hist_data_table, actual_data_table, hist_tuple)
                end)
            end
        end)
        if err_clear_hist ~= nil then
            log.error(err_clear_hist)
            box.rollback()
            return nil, error_repository.get_error_code("STORAGE_003", { error = err_clear_hist })
        end
        box.commit()
    else
        local sys_from_index = get_index_from_space_by_name(
            historical_data_table_name,
            etl_config.get_date_field_end_index_nm()
        )
        if sys_from_index == nil then
            box.begin()
            -- luacheck: ignore err_clear_hist
            _, err_clear_hist = err_storage:pcall(function()
                hist_data_table:pairs():each(function(hist_tuple)
                    if hist_tuple[etl_config.get_date_field_end_nm()] == delta_number - 1 then
                        move_hist_tuple_function(hist_data_table, actual_data_table, hist_tuple)
                    end
                end)
            end)
            box.commit()
        else
            ::iterate::
            box.begin()
            local is_ok, tuples = pcall(
                sys_from_index.select,
                sys_from_index,
                { delta_number - 1 },
                { limit = batch_size }
            )

            if not is_ok then
                log.error(tuples)
                box.rollback()
                return nil, error_repository.get_error_code("STORAGE_003", { error = tuples })
            end

            if #tuples == 0 then
                box.commit()
            else
                _, err_clear_hist = err_storage:pcall(function()
                    for _, tuple in ipairs(tuples) do
                        move_hist_tuple_function(hist_data_table, actual_data_table, tuple)
                    end
                end)

                if err_clear_hist ~= nil then
                    log.error(err_clear_hist)
                    box.rollback()
                    return nil, error_repository.get_error_code("STORAGE_003", { error = err_clear_hist })
                end
                box.commit()
                goto iterate
            end
        end
    end

    return true, nil
end

local function delete_data_from_scd_table_sql(space_name, where_condition)
    checks("string", "?string")

    if get_storage_ddl().spaces[space_name] == nil then
        return nil, error_repository.get_error_code("STORAGE_001", { space = space_name })
    end

    if where_condition == nil then
        box.space[space_name]:truncate()
        return nil, nil
    end

    local where_condition_prep = where_condition or "1 = 1"
    local sql = string.format('delete from "%s" where %s', space_name, where_condition_prep)

    log.debug(string.format("DEBUG: running delete query: {%s}", sql))

    return execute_sql(sql)
end

--- The function calculates a checksum within a delta_number for all of the logical tables in the datamart or for one logical table.
--- @param actual_data_table_name string - space for actual table
--- @param historical_data_table_name string - space for history table
--- @param delta_number number - delta (https://arenadata.atlassian.net/wiki/spaces/DTM/pages/46653935/delta)
--- @param column_list table - optional, columns list for calculate checksum
--- @param normalization number - optional, coefficient of increasing the possible number
----                              of records within the delta. (positive integer greater than or equal to 1, default 1).
local function get_scd_table_checksum(
    actual_data_table_name,
    historical_data_table_name,
    delta_number,
    column_list,
    normalization
)
    checks("string", "string", "number", "?table", "?number")
    local delimeter = ";"

    local is_data_table_ok, err_data = check_table_for_delta_fields(actual_data_table_name, "actual")
    local is_historical_table_ok, err_hist = check_table_for_delta_fields(historical_data_table_name, "history")

    if not is_data_table_ok then
        log.error(err_data)
        return false, err_data
    end

    if not is_historical_table_ok then
        log.error(err_hist)
        return false, err_hist
    end

    local is_tables_meta_ok, tables_meta_err = check_tables_for_delta(
        actual_data_table_name,
        historical_data_table_name
    )

    if not is_tables_meta_ok then
        log.error(tables_meta_err)
        return false, tables_meta_err
    end

    local result = 0

    local norm = 1
    if normalization ~= nil then
        norm = normalization
    end

    local sys_from_index_actual = get_index_from_space_by_name(
        actual_data_table_name,
        etl_config.get_date_field_start_index_nm()
    )
    local sys_from_index_history = get_index_from_space_by_name(
        historical_data_table_name,
        etl_config.get_date_field_start_index_nm()
    )
    local sys_to_index_history = get_index_from_space_by_name(
        historical_data_table_name,
        etl_config.get_date_field_end_index_nm()
    )

    local calc_function = function(tuple)
        local tuple_map = tuple:tomap({ names_only = true })
        local concatenate = {}
        for _, column in pairs(column_list) do
            if tuple_map[column] ~= nil then
                table.insert(
                    concatenate,
                    dtm_digest_utils.convert_lua_types_for_checksum(tuple_map[tostring(column)], delimeter)
                )
            else
                table.insert(concatenate, "")
            end
        end

        local dtm_hash_cols = dtm_digest_utils.dtm_int32_hash(table.concat(concatenate, delimeter))
        result = result + math.floor(dtm_hash_cols / norm)
    end

    local res, err = pcall(function()
        if sys_from_index_actual ~= nil then
            if column_list == nil then
                result = result + sys_from_index_actual:count({ delta_number })
            else
                sys_from_index_actual:pairs({ delta_number }):each(calc_function)
            end
        else
            moonwalker({
                space = box.space[actual_data_table_name],
                examine = function(tuple)
                    return tuple[etl_config.get_date_field_start_nm()] == delta_number
                end,
                actor = calc_function,
            })
        end
        if sys_from_index_history ~= nil then
            if column_list == nil then
                result = result + sys_from_index_history:count({ delta_number })
            else
                sys_from_index_history:pairs({ delta_number }):each(calc_function)
            end
        else
            moonwalker({
                space = box.space[actual_data_table_name],
                examine = function(tuple)
                    return tuple[etl_config.get_date_field_start_nm()] == delta_number
                end,
                actor = calc_function,
            })
        end
        if sys_to_index_history ~= nil then
            if column_list == nil then
                result = result + sys_to_index_history:count({ delta_number - 1, 1 })
            else
                sys_to_index_history:pairs({ delta_number - 1, 1 }):each(calc_function)
            end
        else
            moonwalker({
                space = box.space[actual_data_table_name],
                examine = function(tuple)
                    return tuple[etl_config.get_date_field_start_nm()] == delta_number
                end,
                actor = calc_function,
            })
        end
    end)

    if not res then
        return false, err
    end

    return true, result
end

---index_create - function creates index in space
---@param space_name string - space name for creating index.
---@param index_name string - index name.
---@param params table - index params: type, unique and fields list.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function index_create(space_name, index_name, params)
    checks("string", "string", "table")

    if params.type == nil then
        return nil, err_storage:new("type field must be in params")
    end

    if params.unique == nil then
        return nil, err_storage:new("unique field must be in params")
    end

    local idx = {
        type = params.type,
        unique = params.unique,
        parts = {}
    }

    return err_storage:pcall(function ()
        local space_fields = box.space[space_name]:format()

        for _, f in pairs(params.fields) do
            for _, sf in pairs(space_fields) do
                if sf.name == f then
                    table.insert(idx.parts, { sf.name, sf.type, is_nullable = sf.is_nullable })
                    break
                end
            end
        end

        box.space[space_name]:create_index(index_name, idx)
        return get_storage_ddl(), nil
    end)
end

---index_drop - function drops index in space
---@param space_name string - space name for drop index.
---@param index_name string - index name.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function index_drop(space_name, index_name)
    checks("string", "string")

    return err_storage:pcall(function ()
        box.space[space_name].index[index_name]:drop()
        return get_storage_ddl(), nil
    end)
end

---add_columns - function adds new columns to space
---@param space_name string - space name for apending column.
---@param columns table - list of new columns.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function add_columns(space_name, columns)
    checks("string", "table")
    return err_storage:pcall(function ()
        local new_schema = box.space[space_name]:format()

        for _, c in pairs(columns) do
            table.insert( new_schema, c )
        end

        box.space[space_name]:alter({ name = space_name, format = new_schema})
        return get_storage_ddl(), nil
    end)
end

---drop_columns - function adds new columns to space
---@param space_name string - space name for apending column.
---@param columns table - list of column names for removing.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function drop_columns(space_name, columns)
    checks("string", "table")

    return err_storage:pcall(function ()
        local new_schema = box.space[space_name]:format()

        for _, i in pairs(box.space[space_name].index) do
            for _, j in pairs(i.parts) do
                for _, c in pairs(columns) do
                    if new_schema[j.fieldno].name == c then
                        return nil, err_storage:new("field `"..c.."` used in index `"..i.name.."`")
                    end
                end
            end
        end

        for i, c in pairs(new_schema) do
            for _, rc in pairs(columns) do
                if c.name == rc then
                    table.remove( new_schema, i )
                    break
                end
            end
        end

        box.space[space_name]:alter({ name = space_name, format = new_schema})
        return get_storage_ddl(), nil
    end)
end

---transform_query_to_tuple - function transform sql insert query to tuple with values
---@param query string - sql query.
---@param params table - list of query params.
---@param bucket_count number - count of vshard buckets.
---@return boolean|table - true,nil if dropped | nil,error - otherwise.
local function transform_query_to_tuple(query, params, bucket_count)
    checks("string", "?table", "number")
    return sql_insert.get_tuples(query, params, bucket_count)
end

local function remove_spaces_from_bucket_id_cache(space_names)
    for _, space_name in ipairs(space_names) do
        schema_utils.clean_bucket_id_cache_by_space(space_name)
    end
end

local function init(opts) -- luacheck: no unused args
    _G.insert_tuples = insert_tuples
    _G.drop_space = drop_space
    _G.truncate_space = truncate_space
    _G.drop_spaces = drop_spaces
    _G.drop_spaces_with_prefix = drop_spaces_with_prefix
    _G.storage_drop_all = storage_drop_all
    _G.storage_space_count = storage_space_count
    _G.storage_space_len = storage_space_len
    _G.get_metric = get_metric
    _G.prep_sql = prep_sql
    _G.execute_sql = execute_sql
    _G.set_schema_ddl = set_schema_ddl
    _G.get_storage_ddl = get_storage_ddl
    _G.get_space_format = get_space_format
    _G.check_table_for_delta_fields = check_table_for_delta_fields
    _G.check_tables_for_delta = check_tables_for_delta
    _G.transfer_stage_data_to_scd_table = transfer_stage_data_to_scd_table
    _G.reverse_history_in_scd_table = reverse_history_in_scd_table
    _G.delete_data_from_scd_table_sql = delete_data_from_scd_table_sql
    _G.get_scd_table_checksum = get_scd_table_checksum
    _G.table_mutex_map = mutex_map.get_mutex_map()
    _G.index_create = index_create
    _G.index_drop = index_drop
    _G.add_columns = add_columns
    _G.drop_columns = drop_columns
    _G.transform_query_to_tuple = transform_query_to_tuple
    _G.remove_spaces_from_bucket_id_cache = remove_spaces_from_bucket_id_cache

    query_dbg_opts = query_debug_config.get_query_prof_opts()

    garbage_fiber = fiber.create(function()
        while true do
            collectgarbage("step", 20)
            fiber.sleep(0.2)
        end
    end)

    garbage_fiber:name("GARBAGE_COLLECTOR_FIBER")

    local httpd = cartridge.service_get("httpd")
    httpd:route({ method = "GET", path = "/metrics" }, prometheus.collect_http)

    if opts.is_master then
        box.schema.func.create('sbroad.calculate_bucket_id', { if_not_exists = true, language = 'C' })
    end
    return true
end

local function stop()
    table_mutex_map:clear()
    query_dbg_opts:clear()
    garbage_fiber:cancel()
    return true
end

local function validate_config(conf_new, conf_old) -- luacheck: no unused args
    if type(box.cfg) ~= "function" and not box.cfg.read_only then
        local etl_opts = yaml.decode(conf_new["etl_scd.yml"] or [[]])
            or {
                ["start_field_nm"] = "sysFrom",
                ["end_field_nm"] = "sysTo",
                ["op_field_nm"] = "sysOp",
            }
        local is_etl_opts_ok, etl_opts_err = validate_utils.check_etl_opts(etl_opts)
        if not is_etl_opts_ok then
            return false, etl_opts_err
        end
    end
    return true
end

local function apply_config(conf, opts) -- luacheck: no unused args
    if opts.is_master then -- luacheck: ignore 542
    end
    query_dbg_opts = query_debug_config.get_query_prof_opts()
    schema_utils.init_schema_ddl()
    etl_config.init_etl_opts()
    error_repository.init_error_repo("en")
    success_repository.init_success_repo("en")
    if opts.is_master then
        local res, err = set_schema_ddl()
        if res == nil then
            log.error(err)
        else
            sql_insert.install_triggers()
        end
    end

    return true
end

return {
    role_name = role_name,
    init = init,
    stop = stop,
    get_schema = ddl.get_schema,
    validate_config = validate_config,
    drop_space = drop_space,
    drop_spaces = drop_spaces,
    drop_spaces_with_prefix = drop_spaces_with_prefix,
    apply_config = apply_config,
    dependencies = {
        "cartridge.roles.vshard-storage",
        "cartridge.roles.crud-storage",
    },
    get_metric = get_metric,
    prep_sql = prep_sql,
    execute_sql = execute_sql,
    set_schema_ddl = set_schema_ddl,
    index_create = index_create,
    index_drop = index_drop,
    add_columns = add_columns,
    drop_columns = drop_columns,
    transform_query_to_tuple = transform_query_to_tuple,
    remove_spaces_from_bucket_id_cache = remove_spaces_from_bucket_id_cache,
}
