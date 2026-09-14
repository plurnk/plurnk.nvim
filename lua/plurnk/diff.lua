-- Diff helpers + YOLO toggle. `yolo` is the standing setting (config, :PlurnkYolo);
-- `review` is one prompt's request (:AI? …) and outranks it until that loop ends.
local M = {}
local yolo = false
local review = false
M.is_yolo = function() return yolo end
M.toggle_yolo = function() yolo = not yolo end
M.set_yolo = function(v) yolo = not not v end
M.request_review = function(v) review = not not v end
M.review_requested = function() return review end
return M
