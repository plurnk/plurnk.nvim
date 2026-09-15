-- The editor's standing YOLO setting. Explicit review belongs to a model run.
local M = {}
local yolo = false
M.is_yolo = function() return yolo end
M.toggle_yolo = function() yolo = not yolo end
M.set_yolo = function(v) yolo = not not v end
return M
