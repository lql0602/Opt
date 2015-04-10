
--terralib.settypeerrordebugcallback( function(fn) fn:printpretty() end )

opt = {} --anchor it in global namespace, otherwise it can be collected

local S = require("std")

local C = terralib.includecstring [[
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <cuda_runtime.h>
]]

local function newclass(name)
    local mt = { __name = name }
    mt.__index = mt
    function mt:is(obj)
        return getmetatable(obj) == self
    end
    function mt:__tostring()
        return "<"..name.." instance>"
    end
    function mt:new(obj)
        obj = obj or {}
        setmetatable(obj,self)
        return obj
    end
    return mt
end

local vprintf = terralib.externfunction("cudart:vprintf", {&int8,&int8} -> int)
local function createbuffer(args)
    local Buf = terralib.types.newstruct()
    return quote
        var buf : Buf
        escape
            for i,e in ipairs(args) do
                local typ = e:gettype()
                local field = "_"..tonumber(i)
                typ = typ == float and double or typ
                table.insert(Buf.entries,{field,typ})
                emit quote
                   buf.[field] = e
                end
            end
        end
    in
        [&int8](&buf)
    end
end
printf = macro(function(fmt,...)
    local buf = createbuffer({...})
    return `vprintf(fmt,buf) 
end)

local dims = {{"blockIdx","ctaid"},
              {"gridDim","nctaid"},
              {"threadIdx","tid"},
              {"blockDim","ntid"}}
for i,d in ipairs(dims) do
    local a,b = unpack(d)
    local tbl = {}
    for i,v in ipairs {"x","y","z" } do
        local fn = cudalib["nvvm_read_ptx_sreg_"..b.."_"..v] 
        tbl[v] = `fn()
    end
    _G[a] = tbl
end

__syncthreads = cudalib.nvvm_barrier0
    
struct opt.ImageBinding(S.Object) {
    data : &uint8
    stride : uint64
    elemsize : uint64
}
terra opt.ImageBinding:get(x : uint64, y : uint64) : &uint8
   return self.data + y * self.stride + x * self.elemsize
end

terra opt.ImageBind(data : &opaque, elemsize : uint64, stride : uint64) : &opt.ImageBinding
    var img = opt.ImageBinding.alloc()
    img.data,img.stride,img.elemsize = [&uint8](data),stride,elemsize
    return img
end
terra opt.ImageFree(img : &opt.ImageBinding)
    img:delete()
end

local Problem = newclass("Problem")
local Dim = newclass("dimension")


local ffi = require('ffi')

local problems = {}

-- this function should do anything it needs to compile an optimizer defined
-- using the functions in tbl, using the optimizer 'kind' (e.g. kind = gradientdecesnt)
-- it should generat the field planctor which is the terra function that 
-- allocates the plan

local function compileproblem(tbl,kind)
    local dims = tbl.dims
    local dimindex = { [1] = 0 }
    for i, d in ipairs(dims) do
        assert(Dim:is(d))
        dimindex[d] = i -- index into DimList, 0th entry is always 1
    end

    local costdim = tbl.cost.dim
	local costtyp = tbl.cost.fn:gettype()
    local unknowntyp = costtyp.parameters[3] -- 3rd argument is the image that is the unknown we are mapping over

	local argumenttyps = terralib.newlist()
	for i = 3,#costtyp.parameters do
		argumenttyps:insert(costtyp.parameters[i])
	end

	local graddim = { unknowntyp.metamethods.W, unknowntyp.metamethods.H }

    if kind == "simpleexample" then

		local struct PlanData(S.Object) {
			plan : opt.Plan
			dims : int64[#dims+1]
		}

		local function emitcalltouserfunction(mapdims,actualdims,images,userfn)
			local typ = userfn:gettype()
			local di,dj = dimindex[mapdims[1]],dimindex[mapdims[2]]
			assert(di and dj)
			local imagewrappers = terralib.newlist()
			for i = 3,#typ.parameters do
				local imgtyp = typ.parameters[i]
				local W,H = imgtyp.metamethods.W,imgtyp.metamethods.H
				W,H = dimindex[W],dimindex[H]
				assert(W and H)
				imagewrappers:insert(`imgtyp { W = actualdims[W], H = actualdims[H], impl = @images[i - 3] })
			end
			return `userfn(actualdims[di],actualdims[dj],imagewrappers)
		end
    
		local terra impl(data_ : &opaque, images : &&opt.ImageBinding, params : &opaque)
			var data = [&PlanData](data_)
			var dims = data.dims
			[ emitcalltouserfunction(costdim,dims,images,tbl.cost.fn) ]
			[ emitcalltouserfunction(graddim,dims,images,tbl.gradient) ]
		end
		local terra planctor(actualdims : &uint64) : &opt.Plan
			var pd = PlanData.alloc()
			pd.plan.data = pd
			pd.plan.impl = impl
			pd.dims[0] = 1
			for i = 0,[#dims] do
				pd.dims[i+1] = actualdims[i]
			end
			return &pd.plan
		end
		return Problem:new { planctor = planctor }

	elseif kind == "gradientdescentCPU" then
		
        local struct PlanData(S.Object) {
            plan : opt.Plan
			gradW : int
			gradH : int
			gradStore : unknowntyp
            dims : int64[#dims + 1]
        }

		local function getimages(imagebindings,actualdims)
			local results = terralib.newlist()
			for i,argumenttyp in ipairs(argumenttyps) do
			    local Windex,Hindex = dimindex[argumenttyp.metamethods.W],dimindex[argumenttyp.metamethods.H]
				assert(Windex and Hindex)
				results:insert(`argumenttyp 
				 { W = actualdims[Windex], 
				   H = actualdims[Hindex], 
				   impl = 
				   @imagebindings[i - 1]}) 
			end
			return results
		end

		local images = argumenttyps:map(symbol)
		    
		local terra totalCost(data_ : &opaque, [images])
			var pd = [&PlanData](data_)
			var result = 0.0
			for h = 0,pd.gradH do
				for w = 0,pd.gradW do
					--C.printf("totalCost %d,%d\n", w, h)
				    var v = tbl.cost.fn(w,h,images)
					--C.printf("v = %f\n", v)
					--C.getchar()
					result = result + v
				end
			end
			return result
		end

		local terra max(x : double, y : double)
			if x > y then
				return x
			else
				return y
			end
		end

		local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)

			--C.printf("impl start\n")

			var pd = [&PlanData](data_)
			var params = [&double](params_)
			var dims = pd.dims

			--C.printf("impl A\n")

			var [images] = [getimages(imageBindings,dims)]

			--C.printf("impl B\n")

			-- TODO: parameterize these
			var initialLearningRate = 0.01
			var maxIters = 10000
			var tolerance = 1e-10

			-- Fixed constants (these do not need to be parameterized)
			var learningLoss = 0.8
			var learningGain = 1.1
			var minLearningRate = 1e-25


			var learningRate = initialLearningRate

			--C.printf("impl D\n")

			for iter = 0,maxIters do

				--C.printf("impl iter start\n")

				var startCost = totalCost(data_, images)
				C.printf("iteration %d, cost=%f, learningRate=%f\n", iter, startCost, learningRate)
				--C.getchar()

				--
				-- compute the gradient
				--
				for h = 0,pd.gradH do
					for w = 0,pd.gradW do
						pd.gradStore(w,h) = tbl.gradient(w,h,images)
						--C.printf("%d,%d = %f\n",w,h,pd.gradStore(w,h))
						--C.getchar()
					end
				end

				--
				-- move along the gradient by learningRate
				--
				var maxDelta = 0.0
				for h = 0,pd.gradH do
					for w = 0,pd.gradW do
						var addr = &[ images[1] ](w,h)
						var delta = learningRate * pd.gradStore(w,h)
						--C.printf("delta (%d,%d)=%f\n", w, h, delta)
						@addr = @addr - delta
						maxDelta = max(C.fabsf(delta), maxDelta)
					end
				end

				--
				-- update the learningRate
				--
				var endCost = totalCost(data_, images)
				if endCost < startCost then
					learningRate = learningRate * learningGain

					if maxDelta < tolerance then
						C.printf("terminating, maxDelta=%f\n", maxDelta)
						break
					end
				else
					learningRate = learningRate * learningLoss

					if learningRate < minLearningRate then
						C.printf("terminating, learningRate=%f\n", learningRate)
						break
					end
				end

				--C.printf("impl iter end\n")
			end
		end

		local gradWIndex = dimindex[ graddim[1] ]
		local gradHIndex = dimindex[ graddim[2] ]

		local terra planctor(actualdims : &uint64) : &opt.Plan
			var pd = PlanData.alloc()
            pd.plan.data = pd
			pd.plan.impl = impl
			pd.dims[0] = 1
			for i = 0,[#dims] do
				pd.dims[i+1] = actualdims[i]
			end

			pd.gradW = pd.dims[gradWIndex]
			pd.gradH = pd.dims[gradHIndex]

			pd.gradStore:initCPU(pd.gradW, pd.gradH)

			return &pd.plan
		end
		return Problem:new { planctor = planctor }
	
	elseif kind == "gradientdescentGPU" then
		
        local struct PlanData(S.Object) {
            plan : opt.Plan
			gradW : int
			gradH : int
			gradStore : unknowntyp
			scratchF : &float
			scratchD : &double
            dims : int64[#dims + 1]
        }

		local function getimages(imagebindings,actualdims)
			local results = terralib.newlist()
			for i,argumenttyp in ipairs(argumenttyps) do
			    local Windex,Hindex = dimindex[argumenttyp.metamethods.W],dimindex[argumenttyp.metamethods.H]
				assert(Windex and Hindex)
				results:insert(`argumenttyp 
				 { W = actualdims[Windex], 
				   H = actualdims[Hindex], 
				   impl = 
				   @imagebindings[i - 1]}) 
			end
			return results
		end

		local images = argumenttyps:map(symbol)

		local terra max(x : double, y : double)
			return terralib.select(x > y, x, y)
		end

		local cuda = {}

		terra cuda.computeGradient(pd : PlanData, [images])
			var w = blockDim.x * blockIdx.x + threadIdx.x;
			var h = blockDim.y * blockIdx.y + threadIdx.y;

			--printf("%d, %d\n", w, h)

			if w < pd.gradW and h < pd.gradH then
				pd.gradStore(w,h) = tbl.gradient(w,h,images)
			end
		end

		terra cuda.updatePosition(pd : PlanData, learningRate : double, maxDelta : &double, [images])
			var w = blockDim.x * blockIdx.x + threadIdx.x;
			var h = blockDim.y * blockIdx.y + threadIdx.y;

			--printf("%d, %d\n", w, h)
			
			if w < pd.gradW and h < pd.gradH then
				var addr = &[ images[1] ](w,h)
				var delta = learningRate * pd.gradStore(w,h)
				@addr = @addr - delta

				delta = delta * delta
				var deltaD : double = delta
				var deltaI64 = @[&int64](&deltaD)
				--printf("delta=%f, deltaI=%d\n", delta, deltaI)
				terralib.asm(terralib.types.unit,"red.global.max.u64 [$0],$1;", "l,l", true, maxDelta, deltaI64)
			end
		end

		terra cuda.costSum(pd : PlanData, sum : &float, [images])
			var w = blockDim.x * blockIdx.x + threadIdx.x;
			var h = blockDim.y * blockIdx.y + threadIdx.y;

			if w < pd.gradW and h < pd.gradH then
				var v = tbl.cost.fn(w,h,images)
				var v2 = [float](v * v)
				terralib.asm(terralib.types.unit,"red.global.add.f32 [$0],$1;","l,f",true,sum,v2)
			end
		end
		
		cuda = terralib.cudacompile(cuda, false)
		 
		local terra totalCost(pd : &PlanData, [images])
			var launch = terralib.CUDAParams { (pd.gradW - 1) / 32 + 1, (pd.gradH - 1) / 32 + 1,1, 32,32,1, 0, nil }

			@pd.scratchF = 0.0f
			cuda.costSum(&launch, @pd, pd.scratchF, [images])
			C.cudaDeviceSynchronize()

			return @pd.scratchF
		end

		local terra impl(data_ : &opaque, imageBindings : &&opt.ImageBinding, params_ : &opaque)
			var pd = [&PlanData](data_)
			var params = [&double](params_)
			var dims = pd.dims

			var [images] = [getimages(imageBindings,dims)]

			-- TODO: parameterize these
			var initialLearningRate = 0.01
			var maxIters = 1000
			var tolerance = 1e-10

			-- Fixed constants (these do not need to be parameterized)
			var learningLoss = 0.8
			var learningGain = 1.1
			var minLearningRate = 1e-25

			var learningRate = initialLearningRate

			for iter = 0,maxIters do

				var startCost = totalCost(pd, images)
				C.printf("iteration %d, cost=%f, learningRate=%f\n", iter, startCost, learningRate)
				
				--
				-- compute the gradient
				--
				var launch = terralib.CUDAParams { (pd.gradW - 1) / 32 + 1, (pd.gradH - 1) / 32 + 1,1, 32,32,1, 0, nil }

				--[[
				{ "gridDimX", uint },
                                { "gridDimY", uint },
                                { "gridDimZ", uint },
                                { "blockDimX", uint },
                                { "blockDimY", uint },
                                { "blockDimZ", uint },
                                { "sharedMemBytes", uint },
                                {"hStream" , terra.types.pointer(opaque) } }
								--]]
				--C.printf("gridDimX: %d, gridDimY %d, blickDimX %d, blockdimY %d\n", launch.gridDimX, launch.gridDimY, launch.blockDimX, launch.blockDimY)
				cuda.computeGradient(&launch, @pd, [images])
				C.cudaDeviceSynchronize()
				
				--
				-- move along the gradient by learningRate
				--
				@pd.scratchD = 0.0
				cuda.updatePosition(&launch, @pd, learningRate, pd.scratchD, [images])
				C.cudaDeviceSynchronize()
				C.printf("maxDelta %f\n", @pd.scratchD)
				var maxDelta = @pd.scratchD

				--
				-- update the learningRate
				--
				var endCost = totalCost(pd, images)
				if endCost < startCost then
					learningRate = learningRate * learningGain

					if maxDelta < tolerance then
						break
					end
				else
					learningRate = learningRate * learningLoss

					if learningRate < minLearningRate then
						break
					end
				end
			end
		end

		local gradWIndex = dimindex[ graddim[1] ]
		local gradHIndex = dimindex[ graddim[2] ]

		local terra planctor(actualdims : &uint64) : &opt.Plan
			var pd = PlanData.alloc()
            pd.plan.data = pd
			pd.plan.impl = impl
			pd.dims[0] = 1
			for i = 0,[#dims] do
				pd.dims[i+1] = actualdims[i]
			end

			pd.gradW = pd.dims[gradWIndex]
			pd.gradH = pd.dims[gradHIndex]

			pd.gradStore:initGPU(pd.gradW, pd.gradH)
			C.cudaMallocManaged([&&opaque](&(pd.scratchF)), sizeof(float), C.cudaMemAttachGlobal)
			C.cudaMallocManaged([&&opaque](&(pd.scratchD)), sizeof(double), C.cudaMemAttachGlobal)

			return &pd.plan
		end
		return Problem:new { planctor = planctor }
	end
    
end

function opt.ProblemDefineFromTable(tbl,kind,params)
    local p = compileproblem(tbl,kind,params)
    -- store each problem in a table, and assign it an id
    problems[#problems+1] = p
    p.id = #problems
    return p
end

local function problemdefine(filename,kind,params,pt)
    pt.planctor = nil
    local success,p = xpcall(function() 
        filename,kind = ffi.string(filename), ffi.string(kind)
        local tbl = assert(terralib.loadfile(filename))() 
        assert(type(tbl) == "table")
        local p = opt.ProblemDefineFromTable(tbl,kind,params)
		pt.id,pt.planctor = p.id,p.planctor:getpointer()
		return p
    end,function(err) print(debug.traceback(err,2)) end)
end

struct opt.GradientDescentPlanParams {
    nIterations : uint64
}

struct opt.Plan(S.Object) {
    impl : {&opaque,&&opt.ImageBinding,&opaque} -> {}
    data : &opaque
} 

struct opt.Problem(S.Object) {
    id : int
    planctor : &uint64 -> &opt.Plan
}

terra opt.ProblemDefine(filename : rawstring, kind : rawstring, params : &opaque)
    var pt = opt.Problem.alloc()
    problemdefine(filename,kind,params,pt)
	if pt.planctor == nil then
		pt:delete()
		return nil
	end
    return pt
end 

terra opt.ProblemDelete(p : &opt.Problem)
    -- TODO: deallocate any problem state here (remove from the Lua table,etc.)
    p:delete() 
end

function opt.Dim(name)
    return Dim:new { name = name }
end

local newimage = terralib.memoize(function(typ,W,H)
   local struct Image {
        impl : opt.ImageBinding
        W : uint64
        H : uint64
   }
   function Image.metamethods.__tostring()
      return string.format("Image(%s,%s,%s)",tostring(typ),W.name, H.name)
   end
   Image.metamethods.__apply = macro(function(self,x,y)
     return `@[&typ](self.impl:get(x,y))
   end)
   terra Image:initCPU(actualW : int,actualH : int)
		self.W = actualH
		self.H = actualW
		self.impl.data = [&uint8](C.malloc(actualW * actualH * sizeof(typ)))
		self.impl.elemsize = sizeof(typ)
		self.impl.stride = actualW * sizeof(typ)
   end
   terra Image:initGPU(actualW : int,actualH : int)
		self.W = actualH
		self.H = actualW
		var cudaError = C.cudaMalloc([&&opaque](&(self.impl.data)), actualW * actualH * sizeof(typ))
		self.impl.elemsize = sizeof(typ)
		self.impl.stride = actualW * sizeof(typ)
   end
   Image.metamethods.typ,Image.metamethods.W,Image.metamethods.H = typ,W,H
   return Image
end)

function opt.Image(typ,W,H)
    assert(W == 1 or Dim:is(W))
    assert(H == 1 or Dim:is(H))
    assert(terralib.types.istype(typ))
    return newimage(typ,W,H)
end

terra opt.ProblemPlan(problem : &opt.Problem, dims : &uint64) : &opt.Plan
	return problem.planctor(dims) -- this is just a wrapper around calling the plan constructor
end 

terra opt.PlanFree(plan : &opt.Plan)
    -- TODO: plan should also have a free implementation
    plan:delete()
end

terra opt.ProblemSolve(plan : &opt.Plan, images : &&opt.ImageBinding, params : &opaque)
	return plan.impl(plan.data,images,params)
end

return opt