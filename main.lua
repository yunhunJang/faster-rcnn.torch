require 'torch'
require 'pl'
require 'optim'
require 'image'
require 'nngraph'
require 'cunn'
require 'nms'
require 'gnuplot'

require 'utilities'
require 'Anchors'
require 'BatchIterator'
require 'objective'
require 'Detector'


-- command line options
cmd = torch.CmdLine()
cmd:addTime()

cmd:text()
cmd:text('Training a convnet for region proposals')
cmd:text()

cmd:text('=== Training ===')
cmd:option('-cfg', 'config/imagenet.lua', 'configuration file')
cmd:option('-model', 'models/vgg_small.lua', 'model factory file')
cmd:option('-name', 'imgnet', 'experiment name, snapshot prefix') 
cmd:option('-data', 'ILSVRC2015_DET.t7', 'training data file name')
cmd:option('-pretrain', '', 'network snapshot file name to load')
cmd:option('-snapshot', 1000, 'snapshot interval')
cmd:option('-plot', 100, 'plot training progress interval')
cmd:option('-lr', 1E-4, 'learn rate')
cmd:option('-rms_decay', 0.9, 'RMSprop moving average dissolving factor')
cmd:option('-opti', 'rmsprop', 'Optimizer')

cmd:text('=== Misc ===')
cmd:option('-threads', 8, 'number of threads')
cmd:option('-gpuid', 0, 'device ID (CUDA), (use -1 for CPU)')
cmd:option('-seed', 0, 'random seed (0 = no fixed seed)')

print('Command line args:')
local opt = cmd:parse(arg or {})
print(opt)

print('Options:')
local cfg = dofile(opt.cfg)
print(cfg)

-- system configuration
torch.setdefaulttensortype('torch.FloatTensor')
cutorch.setDevice(opt.gpuid + 1)  -- nvidia tools start counting at 0
torch.setnumthreads(opt.threads)
if opt.seed ~= 0 then
  torch.manualSeed(opt.seed)
  cutorch.manualSeed(opt.seed)
end

function plot_training_progress(prefix, stats)
  local fn = prefix .. '_progress.png'
  gnuplot.pngfigure(fn)
  gnuplot.title('Traning progress over time')
  
  local xs = torch.range(1, #stats.pcls)
  
  gnuplot.plot(
    { 'pcls', xs, torch.Tensor(stats.pcls), '-' },
    { 'preg', xs, torch.Tensor(stats.preg), '-' },
    { 'dcls', xs, torch.Tensor(stats.dcls), '-' },
    { 'dreg', xs, torch.Tensor(stats.dreg), '-' }
  )
 
  gnuplot.axis({ 0, #stats.pcls, 0, 10 })
  gnuplot.xlabel('iteration')
  gnuplot.ylabel('loss')
  
  gnuplot.plotflush()
end

function load_model(cfg, model_path, network_filename, cuda)

  -- get configuration & model
  local model_factory = dofile(model_path)
  local model = model_factory(cfg)
  
  if cuda then
    model.cnet:cuda()
    model.pnet:cuda()
  end
  
  -- combine parameters from pnet and cnet into flat tensors
  local weights, gradient = combine_and_flatten_parameters(model.pnet, model.cnet)
  local training_stats
  if network_filename and #network_filename > 0 then
    local stored = load_obj(network_filename)
    training_stats = stored.stats
    weights:copy(stored.weights)
  end

  return model, weights, gradient, training_stats
end

function graph_training(cfg, model_path, snapshot_prefix, training_data_filename, network_filename)
  print('Reading training data file \'' .. training_data_filename .. '\'.')
  local training_data = load_obj(training_data_filename)
  local file_names = keys(training_data.ground_truth)
  print(string.format("Training data loaded. Dataset: '%s'; Total files: %d; classes: %d; Background: %d)", 
      training_data.dataset_name, 
      #file_names,
      #training_data.class_names,
      #training_data.background_files))
  
  -- create/load model
  local model, weights, gradient, training_stats = load_model(cfg, model_path, network_filename, true)
  if not training_stats then
    training_stats = { pcls={}, preg={}, dcls={}, dreg={} }
  end
  
  local batch_iterator = BatchIterator.new(model, training_data)
  local eval_objective_grad = create_objective(model, weights, gradient, batch_iterator, training_stats)
  
  local rmsprop_state = { learningRate = opt.lr, alpha = opt.rms_decay }
  --local nag_state = { learningRate = opt.lr, weightDecay = 0, momentum = opt.rms_decay }
  local sgd_state = { learningRate = opt.lr, weightDecay = 0.0005, momentum = 0.9 }
  
  for i=1,50000 do
    if i % 5000 == 0 then
      opt.lr = opt.lr / 2
      rmsprop_state.lr = opt.lr
    end
  
    local timer = torch.Timer()
    local _, loss = optim.rmsprop(eval_objective_grad, weights, rmsprop_state)
    --local _, loss = optim.nag(eval_objective_grad, weights, nag_state)
    --local _, loss = optim.sgd(eval_objective_grad, weights, sgd_state)
    
    local time = timer:time().real

    print(string.format('%d: loss: %f', i, loss[1]))
    
    if i%opt.plot == 0 then
      plot_training_progress(snapshot_prefix, training_stats)
    end
    
    if i%opt.snapshot == 0 then
      -- save snapshot
      save_model(string.format('/data1/ilsvrc2016/exp/rcnn/%s_%06d.t7', snapshot_prefix, i), weights, opt, training_stats)
    end
    
  end
  
  -- compute positive anchors, add anchors to ground-truth file
end

function load_image_auto_size(fn, target_smaller_side, max_pixel_size, color_space)
  local img = image.load(path.join(base_path, fn), 3, 'float')
  local dim = img:size()
  
  local w, h
  if dim[2] < dim[3] then
    -- height is smaller than width, set h to target_size
    w = math.min(dim[3] * target_smaller_side/dim[2], max_pixel_size)
    h = dim[2] * w/dim[3]
  else
    -- width is smaller than height, set w to target_size
    h = math.min(dim[2] * target_smaller_side/dim[1], max_pixel_size)
    w = dim[3] * h/dim[2]
  end
  
  img = image.scale(img, w, h)
  
  if color_space == 'yuv' then
    img = image.rgb2yuv(img)
  elseif color_space == 'lab' then
    img = image.rgb2lab(img)
  elseif color_space == 'hsv' then
    img = image.rgb2hsv(img)
  end

  return img, dim
end

function evaluation_demo(cfg, model_path, training_data_filename, network_filename)
  -- load trainnig data
  local training_data = load_obj(training_data_filename)
  
  -- load model
  local model = load_model(cfg, model_path, network_filename, true)
  local batch_iterator = BatchIterator.new(model, training_data)
    
  local red = torch.Tensor({1,0,0})
  local green = torch.Tensor({0,1,0})
  local blue = torch.Tensor({0,0,1})
  local white = torch.Tensor({1,1,1})
  local colors = { red, green, blue, white }
  
  -- create detector
  local d = Detector(model)
    
  for i=1,50 do
  
    -- pick random validation image
    local b = batch_iterator:nextValidation(1)[1]
    local img = b.img
    
    local matches = d:detect(img)
    img = image.yuv2rgb(img)
    -- draw bounding boxes and save image
    for i,m in ipairs(matches) do
      draw_rectangle(img, m.r, green)
    end
    
    image.saveJPG(string.format('output%d.jpg', i), img)
  end
  
end

function measure_map(cfg, model_path, val_data_filename, network_filename)
  -- load trainnig data
  local val_data = load_obj(val_data_filename)
  
  -- load model
  local model = load_model(cfg, model_path, network_filename, true)
  local batch_iterator = BatchIterator.new(model, val_data)
    
  local file_names = keys(val_data.ground_truth)
  local numVal = #file_names
  local red = torch.Tensor({1,0,0})
  local green = torch.Tensor({0,1,0})
  local blue = torch.Tensor({0,0,1})
  local white = torch.Tensor({1,1,1})
  local colors = { red, green, blue, white }
  
  -- create detector
  local d = Detector(model)
    
  --for i=1,numVal do
  for i=1,50 do
  
    -- pick random validation image
    local b = batch_iterator:nextValidation(1)[1]
    local img = b.img
    
    local matches = d:detect(img)
    img = image.yuv2rgb(img)
    -- draw bounding boxes and save image
    for i,m in ipairs(matches) do
      draw_rectangle(img, m.r, green)
    end
    
    image.saveJPG(string.format('./examples/output%d.jpg', i), img)
  end
  
end


graph_training(cfg, opt.model, opt.name, opt.data, opt.pretrain)
--evaluation_demo(cfg, opt.model, opt.data, opt.pretrain)
--measure_map(cfg, opt.model, opt.data, opt.pretrain)

