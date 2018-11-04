-- Create Time 2016/1/29

local gt = cc.exports.gt

local bit = require("app/libs/bit")

require("app/protocols/MessageInit")
require("socket")

local SocketClient = class("SocketClient")

function SocketClient:ctor()
	-- 加载消息打包库
	local msgPackLib = require("app/libs/MessagePack")
	msgPackLib.set_number("integer")
	msgPackLib.set_string("string")
	msgPackLib.set_array("without_hole")
	self.msgPackLib = msgPackLib

	self:initSocketBuffer()

	-- 断线重连超时时间, 同时用做后台唤醒后重连检测时间, 不要随意修改
	gt.resume_time = 8

	-- 发送消息缓冲
	self.sendMsgCache = {}

	-- 注册消息逻辑处理函数回调
	self.rcvMsgListeners = {}

	-- 收发消息超时
	self.isCheckTimeout = false
	self.timeDuration = 0

	-- 是否已经弹出网络错误提示
	self.isPopupNetErrorTips = false

	-- 登录到服务器标识
	self.isStartGame = false

	-- 心跳消息重连时间
	self.heatTime = 4
	-- 发送心跳时间
	self.heartbeatCD = self.heatTime

	-- 检测是否有网络最大时间(秒)
	self.checkInternetMaxTime = 0.5
	-- 检测是否有网络时间
	self.checkInternetTime = self.checkInternetMaxTime
	-- 上次网络状态, 当前网络状态
	self.internetLastStatus = ""
	self.internetCurStatus = ""


	-- 心跳回复时间间隔
	-- 上一次时间间隔
	self.lastReplayInterval = 0
	-- 当前时间间隔
	self.curReplayInterval = 0

	-- 游戏中如果重连了3次,那么直接重连高防ip
	self.totalReconnectTime = 0

	if gt.isIOSPlatform() then
		self.luaBridge = require("cocos/cocos2d/luaoc")
	elseif gt.isAndroidPlatform() then
		self.luaBridge = require("cocos/cocos2d/luaj")
	end

	-- 检测是否为1.0.17以上的版本
	self.isVersion1017 = true

	-- 登录状态,有三次自动重连的机会
	self.loginReconnectNum = 0
	self.scheduleHandler = gt.scheduler:scheduleScriptFunc(handler(self, self.update), 0, false)
	gt.registerEventListener(gt.EventType.NETWORK_ERROR, self, self.networkErrorEvt)

	-- 给下级代理变成vip
	self:registerMsgListener(gt.GC_PLAYER_TYPE, self, self.onPlayerTypeCallback)
	self:registerMsgListener(gt.GC_LUCKY_DRAW_NUM, self, self.onLuckyDrawNumCallback)
end

function SocketClient:initSocketBuffer()
	-- 发送消息缓冲
	self.sendMsgCache = {}
	self.sendingBuffer = ""
	self.remainSendSize = 0
	
	self.msgHeadSize = 12
	-- 接收消息
	self.recvingBuffer = ""
	self.remainRecvSize = self.msgHeadSize --剩余多少数据没有接受完毕,2:头部字节数
	self.recvState = "Head"
end

-- start --
--------------------------------
-- @class function
-- @description 和指定的ip/port服务器建立socket链接
-- @param serverIp 服务器ip地址
-- @param serverPort 服务器端口号
-- @param isBlock 是否阻塞
-- @return socket链接创建是否成功
-- end --
function SocketClient:connect(serverIp, serverPort, isBlock)
	if not serverIp or not serverPort then
		gt.log("serverIp or serverPort = nil")
		return
	end

	self:initSocketBuffer()

	self.serverIp = serverIp
	self.serverPort = serverPort
	self.isBlock = isBlock

	-- tcp 协议 socket
	-- local tcpConnection, errorInfo = socket.tcp()
	gt.log("SocketClient:connect serverIp = " .. serverIp .. ", serverPort = " .. serverPort)
	local tcpConnection, errorInfo = self:getTcp(serverIp)
 	if not tcpConnection then
		gt.log(string.format("Connect failed when creating socket | %s", errorInfo))
		gt.dispatchEvent(gt.EventType.NETWORK_ERROR, errorInfo)
		return false
	end
	self.tcpConnection = tcpConnection
	-- disables the Nagle's algorithm
	tcpConnection:setoption("tcp-nodelay", true)
	-- 和服务器建立tcp链接
	tcpConnection:settimeout(isBlock and 8 or 0)
	local connectCode, errorInfo = tcpConnection:connect(serverIp, serverPort)
	-- print("=======新的ip，端口2",self.serverIp, self.serverPort,connectCode, errorInfo)
	if connectCode == 1 then
		self.isConnectSucc = true
		gt.log("Socket connect success!")
	else
		gt.log(string.format("Socket %s Connect failed | %s", (isBlock and "Blocked" or ""), errorInfo))
		gt.dispatchEvent(gt.EventType.NETWORK_ERROR, errorInfo)
		return false
	end
	self.tcpConnection:settimeout(0)
	-- if not self.scheduleHandler then
	-- 	self.scheduleHandler = gt.scheduler:scheduleScriptFunc(handler(self, self.update), 0, false)
	-- end
	return true
end

function SocketClient:getHttpServerIp()
	local servername = "fuzhou"
	local srcSign = string.format("%s%s", gt.unionid, servername)
	local sign = cc.UtilityExtension:generateMD5(srcSign, string.len(srcSign))
	local xhr = cc.XMLHttpRequest:new()
	xhr.responseType = cc.XMLHTTPREQUEST_RESPONSE_JSON
	-- local refreshTokenURL = string.format("http://web.ishuishui.com/GetIP.php")
	local refreshTokenURL = string.format("http://secureapi.ishuishui.com/security/server/getIPbyZoneUid")
	xhr:open("POST", refreshTokenURL)
	local function onResp()
		gt.log("xhr.readyState = " .. xhr.readyState .. ", xhr.status = " .. xhr.status)
		gt.log("xhr.statusText = " .. xhr.statusText)
		if xhr.readyState == 4 and (xhr.status >= 200 and xhr.status < 207) then
			-- local response = string.sub(xhr.response,4)
			require("json")
			local respJson = json.decode(xhr.response)
			if respJson.errorCode == 0 then -- 服务器现在是 字符"0",应该修改为 数字0
				-- errorCode为0则说明成功,否则不成功
				print("=====selfServer,成功")
				self.serverIp = respJson.ip -- 获得可用ip
				self:connect(self.serverIp, self.serverPort, self.isBlock)
				self:reLogin()
			else
				-- 如果不成功,那么走云盾.如果云盾的ip仍然不能用(一个是取得时候不能用,那么直接取
				-- 高防ip,还一个是获取之后,connect不能用,那么还得用自己的高防ip),那么走自己的高防ip
				print("=====selfServer,失败1")
				self:getIPByState()
				self:connect(self.serverIp, self.serverPort, self.isBlock)
			end
		elseif xhr.readyState == 1 and xhr.status == 0 then
			-- 请求出错,那么去取云盾的ip
			print("=====selfServer,失败2")
			self:getIPByState()
			self:connect(self.serverIp, self.serverPort, self.isBlock)
		end
		xhr:unregisterScriptHandler()
	end
	xhr:registerScriptHandler(onResp)
	xhr:send(string.format("servername=%s&uuid=%s&sign=%s", servername, gt.unionid, sign))
end

-- ###########################################

function SocketClient:getCdnIp()
	local playCount = tonumber(self:getPlayCount())
	if playCount ~= nil then
		local filename = nil
		local num = 0
		if playCount < 11 then
			num = self:getAscii(gt.unionid)
		elseif playCount < 21 then
			num = gt.chu_wan
		elseif playCount < 51 then
			num = gt.zhong_wan
		elseif playCount < 101 then
			num = gt.gao_wan
		else
			num = gt.gu_wan
		end
		if num > 0 and num < 9 then
			filename = self:getFileByNum(num)
			if filename then
				self:getYoYoFile(filename)
				return true
			end
		end
	end
	self:getIPByState()
	self:connect(self.serverIp, self.serverPort, self.isBlock)
end

function SocketClient:getPlayCount()
	local playCount = cc.UserDefault:getInstance():getStringForKey("yoyo_name")
	if playCount ~= "" then
		local s = string.find(playCount, gt.name_s)
		local e = string.find(playCount, gt.name_e)
		if s and e then
			return string.sub(playCount, s + string.len(gt.name_s), e - 1)
		end
	end
	return 0
end

function SocketClient:savePlayCount(count)
	local name = gt.name_s .. count .. gt.name_e
	cc.UserDefault:getInstance():setStringForKey("yoyo_name", name)
end

function SocketClient:getAscii(uuid)
	if not uuid then
		return 1
	end
	local ascii = string.byte(string.sub(uuid, #uuid - 1))
	return (ascii % 4) + 1
end

function SocketClient:getFileByNum(num)
	local filename = "s_1_3_1_4_" .. num .. "_2_4_3"
	local md5 = cc.UtilityExtension:generateMD5(filename, string.len(filename))
	return "http://zhuanzhuanmj.oss-cn-hangzhou.aliyuncs.com/" .. md5 .. ".txt"
end

function SocketClient:getYoYoFile(filename)
	if self.xhr == nil then
        self.xhr = cc.XMLHttpRequest:new()
        self.xhr:retain()
        self.xhr.timeout = 10 -- 设置超时时间
    end
    self.xhr.responseType = cc.XMLHTTPREQUEST_RESPONSE_JSON
    local refreshTokenURL = filename
    self.xhr:open("GET", refreshTokenURL)
    self.xhr:registerScriptHandler(handler(self, self.onYoYoResp))
    self.xhr:send()
end

function SocketClient:onYoYoResp()
	-- 默认高防
    if self.xhr.readyState == 4 and (self.xhr.status >= 200 and self.xhr.status < 207) then
        self.dataRecv = self.xhr.response -- 获取到数据
        local data = tostring(self.xhr.response)
        if data then
        	gt.log("onYoYoResp data = " .. data)
			local ipTab = string.split(data, ".")
			if #ipTab == 4 then -- 正确的ip地址
				self.serverIp = data
				gt.log("onYoYoResp ip = " .. data)
				self.xhr:unregisterScriptHandler()
				self:connect(self.serverIp, self.serverPort, self.isBlock)
				self:reLogin()
				return true
			end
        end
    elseif self.xhr.readyState == 1 and self.xhr.status == 0 then
        -- 网络问题,异常断开
    end
    self.xhr:unregisterScriptHandler()
    
	self:getIPByState()
	self:connect(self.serverIp, self.serverPort, self.isBlock)
end

-- ###########################################

function SocketClient:getIPByState()
	if not self.curIpState then -- 没有传state进来
		self.curIpState = "ipServer"
	else
		if self.curIpState == "ipServer" then
			self.curIpState = "gaofang"
		elseif self.curIpState == "gaofang" then
			self.curIpState = "ipServer"
		end
	end
	gt.log("当前socket状态 : " .. self.curIpState)
	if self.curIpState == "ipServer" then
		self:getHttpServerIp()
	-- elseif self.curIpState == "cdn" then
		-- self:getCdnIp()
	-- elseif self.curIpState == "yundun" then
	-- 	-- 如果是正式包,那么取ip
	-- 	local isRightIp = false
	-- 	if gt.isIOSPlatform() then
	-- 		local ok = nil
	-- 		local ret = nil
			
	-- 		ok, ret = self.luaBridge.callStaticMethod("AppController", "registerYunIP", {teamname = "bXCnf_DhvZ_wbB-S0FFW0WXpHQF26BqLjz7ijPVhmNKM0hCq_KtVRdPsYVt9qwt2UCM17BcRODg9sF+nWrXkM9Kk1vNQg5CaQo9ivWVO65nmqHUZo4YBl5RhkNghcDp9ZF1Ooj698NnBWUmYz4w5cUXilOe8iPmW_mn6VPk5O5q4UA4S+TJoEgczy9QdjqheVsvZJ3y6xYFEFUo3eyZkFRWl-5WGjEJDovDnzJ3GSRJ5qsvL2_neeClxYhuYs2PqaDjJgpihrZ-f9bblbB1kfNmUuV_RT1nZwMtPLmfThPG3TDMyCp27zUeXVUgaYcfTO-2Qm_o_QNBLdhXYsmsVkHg8qHRlJYavWWQ9gt3Zi"})
	-- 		ok, ret = self.luaBridge.callStaticMethod("AppController", "getYunIP", {ipKey = "ishuishui1.u0qr4x4wk3.aliyungf.com", uuidkey = gt.unionid})
			
	-- 		local ipTab = string.split(ret, ".")
	-- 		if #ipTab == 4 then -- 正确的ip地址
	-- 			isRightIp = true
	-- 			self.serverIp = ret
	-- 		end
	-- 	elseif gt.isAndroidPlatform() then
	-- 		local ok = nil
	-- 		local ret = nil
			
	-- 		ok, ret = self.luaBridge.callStaticMethod("org/cocos2dx/lua/AppActivity", "getIP", {"ishuishui1.u0qr4x4wk3.aliyungf.com", gt.unionid, "bXCnf_DhvZ_wbB-S0FFW0WXpHQF26BqLjz7ijPVhmNKM0hCq_KtVRdPsYVt9qwt2UCM17BcRODg9sF+nWrXkM9Kk1vNQg5CaQo9ivWVO65nmqHUZo4YBl5RhkNghcDp9ZF1Ooj698NnBWUmYz4w5cUXilOe8iPmW_mn6VPk5O5q4UA4S+TJoEgczy9QdjqheVsvZJ3y6xYFEFUo3eyZkFRWl-5WGjEJDovDnzJ3GSRJ5qsvL2_neeClxYhuYs2PqaDjJgpihrZ-f9bblbB1kfNmUuV_RT1nZwMtPLmfThPG3TDMyCp27zUeXVUgaYcfTO-2Qm_o_QNBLdhXYsmsVkHg8qHRlJYavWWQ9gt3Zi"}, "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")

	-- 		local ipTab = string.split(ret, ".")
	-- 		if #ipTab == 4 then -- 正确的ip地址
	-- 			isRightIp = true
	-- 			self.serverIp = ret
	-- 		end
	-- 	end
	-- 	-- 如果获取云盾ip失败,那么走自己的高防ip
	-- 	if isRightIp == false then
	-- 		self.serverIp = "www.ishuishuiyx.com"
	-- 	end
	elseif self.curIpState == "gaofang" then
		self.serverIp = "fj.ishuishuiyx.com" --"www.ishuishuiyx.com"
	end
end

function SocketClient:connectResume()
	if gt.isDebugPackage and gt.debugInfo and not gt.debugInfo.YunDun then
		self.serverIp = gt.debugInfo.ip
		self.serverPort = gt.debugInfo.port
	else
		self.serverIp = gt.LoginServer.ip
		self.serverPort = gt.LoginServer.port
		-- if self.isStartGame == false then -- 还处在登录状态,如果重连,则说明ipserver返回的ip不可用,那么走云盾.
		-- 	local curRunScene = display.getRunningScene() -- LoginScene.lua
		-- 	self.serverIp = curRunScene:getIPByState()
		-- else -- 游戏中
		-- 	if self.isReconnectFlag == false then -- 如果这个ip还没有进行重连过,那么用此ip重新连接一次
		-- 		self.isReconnectFlag = true
		-- 		self.serverIp = self.serverIp
		-- 		gt.log("重新链接当前ip : " .. self.serverIp .. ", port : " .. self.serverPort)
		-- 	else
		-- 		-- gt.log("重新获取ip!")
		-- 		-- self:getIPByState()
		-- 		-- gt.log("获取后状态 : " .. self.curIpState)
		-- 		-- if self.curIpState == "ipServer" or self.curIpState == "cdn" then -- 这种状态需要服务器返回ip之后方可重连server
		-- 		-- 	return false
		-- 		-- end
		-- 		-- gt.log("重新获取ip : " .. self.serverIp .. ", port : " .. self.serverPort)
		-- 	end
		-- end
	end
	self:connect(self.serverIp, self.serverPort, self.isBlock)
	return true
end

-- start --
--------------------------------
-- @class function
-- @description 恢复链接
-- @param
-- @param
-- @param
-- @return
-- end --
function SocketClient:connectResumeBK()
	if self.isConnectSucc or not self.tcpConnection then
		-- 连接成功或者socket.tcp句柄创建失败
		return
	end

	local r, w, e = socket.select({self.tcpConnection}, {self.tcpConnection}, 0.02)
	if not w or e == "timeout" then
		gt.log("Socket select timeout")
		-- gt.dispatchEvent(gt.EventType.NETWORK_ERROR)
		return false
	end
	local connectCode, errorInfo = self.tcpConnection:connect(self.serverIp, self.serverPort)
	if errorInfo ~= "already connected" then
		gt.log("Socket connect errorInfo: " .. errorInfo)
		-- gt.dispatchEvent(gt.EventType.NETWORK_ERROR)
		return false
	end
	self.isConnectSucc = true
	-- 一旦重新连接上,则此ip又可作为下次连接的ip使用
	self.isReconnectFlag = false
	self.curIpState = nil
	return true
end

-- start --
--------------------------------
-- @class function
-- @description 关闭socket链接
-- end --
function SocketClient:close()
	-- if self.scheduleHandler then
	-- 	gt.scheduler:unscheduleScriptEntry(self.scheduleHandler)
	-- 	self.scheduleHandler = nil
	-- end
	if self.tcpConnection then
		self.tcpConnection:close()
	end
	self.tcpConnection = nil
	self.isConnectSucc = false
	self.sendMsgCache = {}

	self.isCheckTimeout = false
	self.isPopupNetErrorTips = false

	gt.log("Socket close connect!")
end

-- 进行一些必须的善后处理,更包的时候,再把清理定时器等拿到这个函数内
function SocketClient:clearSocket()
	-- 游戏中如果重连了3次,那么直接重连高防ip
	self.totalReconnectTime = 0
	-- 登录状态,有三次自动重连的机会
	self.loginReconnectNum = 0
end

-- start --
--------------------------------
-- @class function
-- @description 发送消息放入到缓冲,非真正的发送
-- @param msgTbl 消息体
-- end --
function SocketClient:sendMessage(msgTbl)
	if msgTbl.m_msgId ~= 15 and msgTbl.m_msgId ~= 16 then
		dump(msgTbl)
	end

	-- 打包成messagepack格式
	local msgPackData = self.msgPackLib.pack(msgTbl)
	local msgLength = string.len(msgPackData)
	local len = self:luaToCByShort(msgLength)

	local curTime = os.time()
    gt.log("curTime = " .. curTime)
	local time = self:luaToCByInt(curTime)
    gt.log("time int = " .. time)
	local msgId = self:luaToCByInt(msgTbl.m_msgId * ((curTime % 10000) + 1))
    gt.log("msgId by int = " .. msgId)
	local checksum = self:getCheckSum(time .. msgId, msgLength, msgPackData)
	local msgToSend = len .. checksum .. time .. msgId .. msgPackData
	
	-- 放入到消息缓冲
	table.insert(self.sendMsgCache, msgToSend)
end

function SocketClient:getCheckSum(time, msgLength, msgPackData)
	local crc = ""
	local len = string.len(time) + msgLength
	if len < 8 then
		crc = self:CRC(time .. msgPackData, len)
	else
		crc = self:CRC(time .. msgPackData, 8)
	end
	return self:luaToCByShort(crc)
end

function SocketClient:luaToCByShort(value)
	return string.char(value % 256) .. string.char(math.floor(value / 256))
end


function SocketClient:luaToCByInt(value)
    local lowByte1 = string.char(math.floor(value / (256 * 256 * 256)))
	local lowByte2 = string.char(math.floor(value / (256 * 256) % 256))
	local lowByte3 = string.char(math.floor(value / 256) % 256)
	local lowByte4 = string.char(value % 256)
	return lowByte4 .. lowByte3 .. lowByte2 .. lowByte1
end
--[[
function SocketClient:luaToCByInt(value)
	local lowByte1 = string.char(((value / 256) / 256) / 256)
	local lowByte2 = string.char(((value / 256) / 256) % 256)
	local lowByte3 = string.char((value / 256) % 256)
	local lowByte4 = string.char(value % 256)
	return lowByte4 .. lowByte3 .. lowByte2 .. lowByte1
end
--]]
function SocketClient:CRC(data, length)
    local sum = 65535
    for i = 1, length do
        local d = string.byte(data, i)    -- get i-th element, like data[i] in C
        sum = self:ByteCRC(sum, d)
    end
    return sum
end

function SocketClient:ByteCRC(sum, data)
    -- sum = sum ~ data
    local sum = bit:_xor(sum, data)
    for i = 0, 3 do     -- lua for loop includes upper bound, so 7, not 8
        -- if ((sum & 1) == 0) then
        if (bit:_and(sum, 1) == 0) then
            sum = sum / 2
        else
            -- sum = (sum >> 1) ~ 0xA001  -- it is integer, no need for string func
            sum = bit:_xor((sum / 2), 0x70B1)
        end
    end
    return sum
end

-- start --
--------------------------------
-- @class function
-- @description 发送消息
-- @param msgTbl 消息表结构体
-- end --
function SocketClient:send()
	if not self.isConnectSucc or not self.tcpConnection then
		-- 链接未建立
		return false
	end

	if #self.sendMsgCache <= 0 then
		return true
	end

	-- dump(self.sendMsgCache)
	
	local sendSize = 0
	local errorInfo = ""
	local sendSizeWhenError = 0
	if self.remainSendSize > 0 then --还有剩余的数据没有发送完毕，接着发送
		local totalSize = string.len(self.sendingBuffer)
		local beginPos = totalSize - self.remainSendSize + 1
		sendSize, errorInfo, sendSizeWhenError = self.tcpConnection:send(self.sendingBuffer, beginPos)
	else
		self.sendingBuffer = self.sendMsgCache[1]
		self.remainSendSize = string.len(self.sendingBuffer)
		sendSize, errorInfo, sendSizeWhenError = self.tcpConnection:send(self.sendingBuffer)
	end
	
	if errorInfo == nil then
		self.remainSendSize = self.remainSendSize - sendSize
		if self.remainSendSize == 0 then  --说明已经发送完毕
			table.remove(self.sendMsgCache, 1)  --移除第一个
			self.sendingBuffer = ""
			-- gt.log("sendSize = " .. sendSize)
			
			-- self.isCheckTimeout = true
			-- self.timeDuration = 0
		end
	else
		if errorInfo == "timeout" then --由于是异步socket，并且timeout为0，luasocket则会立即返回不会继续等待socket可写事件
			if sendSizeWhenError ~= nil and sendSizeWhenError > 0 then
				self.remainSendSize = self.remainSendSize - sendSizeWhenError

				gt.log("Send time out. Had sent size:" .. sendSizeWhenError)
			end
		else
			gt.log("Send failed errorInfo:" .. errorInfo)
			return false
		end
	end
		
	return true
end

-- start --
--------------------------------
-- @class function
-- @description 接收消息并且分发到注册的消息回调
-- end --
function SocketClient:receive()
	if not self.isConnectSucc or not self.tcpConnection then
		-- 链接未建立
		return
	end
	
	local messageQueue = {}
	self:receiveMessage(messageQueue)
	
	if #messageQueue <= 0 then
		return
	end

	-- gt.log("Recv meesage package:" .. #messageQueue)
	
	for i,v in ipairs(messageQueue) do
		if v.m_msgId ~= 15 and v.m_msgId ~= 16 then
			dump(v)
		end
		self:dispatchMessage(v)
	end
end

-- start --
--------------------------------
-- @class function
-- @description 接收消息内容
-- @param sizeLeft 剩余字节数
-- @param buffer 缓冲区
-- @return 接收的消息体
-- end --
-- function SocketClient:receiveBuffer(sizeLeft, buffer)
-- 	if sizeLeft <= 0 then
-- 		return buffer
-- 	end
-- 	local rcvContent, errorInfo, partialContent = self.tcpConnection:receive(sizeLeft)
-- 	if errorInfo == "closed" then
-- 		gt.log("Socket closed!")
-- 		-- gt.dispatchEvent(gt.EventType.NETWORK_ERROR, errorInfo)
-- 		return nil
-- 	elseif errorInfo == "timeout" then
-- 		gt.log("Socket receive timeout!")
-- 		-- buffer = buffer .. partialContent
-- 		-- return self:receiveBuffer(sizeLeft - #partialContent, buffer)
-- 		-- gt.dispatchEvent(gt.EventType.NETWORK_ERROR)
-- 		return nil
-- 	else
-- 		gt.log("Success receive size: " .. #rcvContent)
-- 		buffer = buffer .. rcvContent
-- 		return self:receiveBuffer(sizeLeft - #rcvContent, buffer)
-- 	end
-- end

function SocketClient:receiveMessage(messageQueue)
	if self.remainRecvSize <= 0 then
		return true
	end

	local recvContent,errorInfo,otherContent = self.tcpConnection:receive(self.remainRecvSize)
	if errorInfo ~= nil then
		if errorInfo == "timeout" then --由于timeout为0并且为异步socket，不能认为socket出错
			if otherContent ~= nil and #otherContent > 0 then
				self.recvingBuffer = self.recvingBuffer .. otherContent
				self.remainRecvSize = self.remainRecvSize - #otherContent

				gt.log("recv timeout, but had other content. size:" .. #otherContent)
			end
			
			return true
		else	--发生错误，这个点可以考虑重连了，不用等待heartbeat
			gt.log("Recv failed errorinfo:" .. errorInfo)
			return false
		end
	end
	
	local contentSize = #recvContent
	self.recvingBuffer = self.recvingBuffer .. recvContent
	self.remainRecvSize = self.remainRecvSize - contentSize

	-- gt.log("success recv size:" .. contentSize ..  "   remainRecvSize is:" .. self.remainRecvSize)
	
	if self.remainRecvSize > 0 then	--等待下次接收
		return true
	end
	
	if self.recvState == "Head" then
		self.remainRecvSize = string.byte(self.recvingBuffer, 2) * 256 + string.byte(self.recvingBuffer, 1)
		self.recvingBuffer = ""
		self.recvState = "Body"
	elseif self.recvState == "Body" then
		local messageData = self.msgPackLib.unpack(self.recvingBuffer)
		table.insert(messageQueue, messageData)
		self.remainRecvSize = self.msgHeadSize  --下个包头
		self.recvingBuffer = ""
		self.recvState = "Head"
	end

	--继续接数据包
	--如果有大量网络包发送给客户端可能会有掉帧现象，但目前不需要考虑，解决方案可以1.设定总接收时间2.收完body包就不在继续接收了
	return self:receiveMessage(messageQueue)
end

-- start --
--------------------------------
-- @class function
-- @description 注册msgId消息回调
-- @param msgId 消息号
-- @param msgTarget
-- @param msgFunc 回调函数
-- end --
function SocketClient:registerMsgListener(msgId, msgTarget, msgFunc)
	-- if not msgTarget or not msgFunc then
	-- 	return
	-- end
	self.rcvMsgListeners[msgId] = {msgTarget, msgFunc}
end

-- start --
--------------------------------
-- @class function
-- @description 注销msgId消息回调
-- @param msgId 消息号
-- end --
function SocketClient:unregisterMsgListener(msgId)
	self.rcvMsgListeners[msgId] = nil
end

-- start --
--------------------------------
-- @class function removeTargetAllEventListener
-- @description 移除target的注册的全部事件
-- @param target self
-- @return
-- end --
function SocketClient:removeTargetAllEventListener(target)
	if not target then
		return
	end
	-- 移除target注册的全部事件
	for _, listener in pairs(self.rcvMsgListeners) do
        if type(listener[1]) ==  type(target) then
            if listener[1] == target then
               self.rcvMsgListeners[_] = nil
		       --table.remove(self.rcvMsgListeners, _)
	        end
        end
	end
end

-- start --
--------------------------------
-- @class function
-- @description 分发消息
-- @param msgTbl 消息表结构
-- end --
function SocketClient:dispatchMessage(msgTbl)
	local rcvMsgListener = self.rcvMsgListeners[msgTbl.m_msgId]
	-- if msgTbl.m_msgId == gt.GC_PLAYER_TYPE then
		-- dump(rcvMsgListener)
	-- end
	if rcvMsgListener then
		rcvMsgListener[2](rcvMsgListener[1], msgTbl)
	else
		gt.log("Could not handle Message " .. tostring(msgTbl.m_msgId))
	end
end

function SocketClient:setIsStartGame(isStartGame)
	self.isStartGame = isStartGame

	self.loginReconnectNum = 10

	-- 心跳消息回复
	self:registerMsgListener(gt.GC_HEARTBEAT, self, self.onRcvHeartbeat)
end

-- start --
--------------------------------
-- @class function
-- @description 向服务器发送心跳
-- @param isCheckNet 检测和服务器的网络连接
-- end --
function SocketClient:sendHeartbeat(isCheckNet)
	if not self.isStartGame then
		return
	end

	local msgTbl = {}
	msgTbl.m_msgId = gt.CG_HEARTBEAT
	self:sendMessage(msgTbl)


    local socket = require("socket")
    self.sendHBTime = socket.gettime()


	self.curReplayInterval = 0

	self.isCheckNet = isCheckNet
	if isCheckNet then
		-- 防止重复发送心跳,直接进入等待回复状态
		self.heartbeatCD = -1
	end
	-- print("========发送心跳时间",os.time())
end

-- start --
--------------------------------
-- @class function
-- @description 服务器回复心跳
-- @param msgTbl
-- end --
function SocketClient:onRcvHeartbeat(msgTbl)
	self.heartbeatCD = self.heatTime
	self.lastReplayInterval = self.curReplayInterval
	-- print("========发送回复时间",os.time())

    local socket = require("socket")
	local time = socket.gettime()
	local delayTime = (time - self.sendHBTime - 1/120) * 1000
   
  
    gt.dispatchEvent("NET_DELAY", delayTime)
end

-- start --
--------------------------------
-- @class function
-- @description 获取上一次心跳回复时间间隔用来判断网络信号强弱
-- @return 上一次心跳回复时间间隔
-- end --
function SocketClient:getLastReplayInterval()
	return self.lastReplayInterval
end

function SocketClient:checkIsInternet(delta)
    --gt.log("Enter->" .. "SocketClient:checkIsInternet")
	if not self.isVersion1017 then
		return true
	end

	if not self.isStartGame then
		return true
	end

	self.checkInternetTime = self.checkInternetTime - delta
	if self.checkInternetTime < 0 then
		self.checkInternetTime = self.checkInternetMaxTime
		local ok = false
		-- 保存上一次状态
		self.internetLastStatus = self.internetCurStatus
		if gt.isIOSPlatform() then
			-- 获取新的状态
			ok, self.internetCurStatus = self.luaBridge.callStaticMethod(
				"AppController", "getInternetStatus", nil)
		elseif gt.isAndroidPlatform() then
			ok, self.internetCurStatus = self.luaBridge.callStaticMethod(
				"org/cocos2dx/lua/AppActivity", "getCurrentNetworkType", nil, "()Ljava/lang/String;")
		end
		if self.internetLastStatus == "Not" and self.internetCurStatus ~= "Not" then
			self.curReplayInterval = gt.resume_time
			gt.removeLoadingTips()
			gt.log("已获取网络,重新登录!")
		end
		if self.internetCurStatus == "Not" and self.internetLastStatus ~= "Not" then
			gt.showLoadingTips(gt.getLocationString("LTKey_0001"))
			gt.log("请检查网络!")
			return false
		end
	end
	-- 当上一次状态为空, 则保留上一次状态
	if self.internetCurStatus == "Not" then
		return false
	end
	return true
end

function SocketClient:update(delta)
	--gt.log("Enter->" .. "SocketClient:update")
	local isInternet = self:checkIsInternet(delta)
	if not isInternet then
		return false
	end

	self:send()
	self:receive()

	-- 检测网络链接超时
	-- if self.isCheckTimeout then
	-- 	self.timeDuration = self.timeDuration + delta
	-- 	if self.timeDuration >= 16 then
	-- 		self.isCheckTimeout = false
	-- 		self.timeDuration = 0
	-- 		gt.dispatchEvent(gt.EventType.NETWORK_ERROR, "timeout")
	-- 	end
	-- end
	if self.isStartGame then
		if self.heartbeatCD >= 0 then
			-- 登录服务器后开始发送心跳消息
			self.heartbeatCD = self.heartbeatCD - delta
			if self.heartbeatCD < 0 then
				-- 发送心跳
				self:sendHeartbeat(true)
			end
		else
			-- 心跳回复时间间隔
			self.curReplayInterval = self.curReplayInterval + delta
			if self.isCheckNet and self.curReplayInterval >= gt.resume_time then
				gt.log("断线重连开始 self.curReplayInterval = " .. self.curReplayInterval .. ", gt.resume_time = " .. gt.resume_time)
				gt.resume_time = 8
				self.isCheckNet = false
				-- 心跳时间稍微长一些,等待重新登录消息返回
				self.heartbeatCD = self.heatTime
				-- 监测网络状况下,心跳回复超时发送重新登录消息
				self:reloginServer()
			end
		end
	end
end

function SocketClient:reloginServer()
	gt.showLoadingTips(gt.getLocationString("LTKey_0001"))

	-- 链接关闭重连
	self:close()
	local result = self:connectResume()
	if not result then
		return false
	end

	-- -- 发送重联消息
	-- local msgToSend = {}
	-- msgToSend.m_msgId = gt.CG_RECONNECT
	-- msgToSend.m_seed = gt.loginSeed
	-- msgToSend.m_id = gt.playerData.uid
	-- local catStr = tostring(gt.loginSeed)
	-- msgToSend.m_md5 = cc.UtilityExtension:generateMD5(catStr, string.len(catStr))
	-- self:sendMessage(msgToSend)
	self:reLogin()
end

function SocketClient:reLogin()
	local runningScene = display.getRunningScene()
	if runningScene and runningScene["reLogin"] then
		runningScene:reLogin()
	end
end

function SocketClient:networkErrorEvt(eventType, errorInfo)
	gt.log("networkErrorEvt errorInfo:" .. errorInfo)
	if self.isPopupNetErrorTips then
		return
	end

	if self.isStartGame then
		return
	end

	local tipInfoKey = "LTKey_0047"
	if errorInfo == "connection refused" then
		-- 连接被拒提示服务器维护中
		tipInfoKey = "LTKey_0002"
	end

	if self.loginReconnectNum < 3 and self.isStartGame == false then
		self.loginReconnectNum = self.loginReconnectNum + 1
		self:connectResume()
		return
	end

	self.isPopupNetErrorTips = true

	require("app/views/NoticeTips"):create(gt.getLocationString("LTKey_0007"), gt.getLocationString(tipInfoKey),
		function()
			self.isPopupNetErrorTips = false
			gt.removeLoadingTips()

			if errorInfo == "timeout" then
				-- 检测网络连接
				self:sendHeartbeat(true)
			end
		end, nil, true)
end

function SocketClient:getTcp(host)
	if not gt.isInReview then
		return socket.tcp()
	end
	local isipv6_only = false
	local addrinfo, err = socket.dns.getaddrinfo(host);
	if addrinfo then
		for i,v in ipairs(addrinfo) do
			if v.family == "inet6" then
				isipv6_only = true;
				break
			end
		end
	end
	print("isipv6_only", isipv6_only)
	if isipv6_only then
		return socket.tcp6()
	else
		return socket.tcp()
	end
end

function SocketClient:onPlayerTypeCallback(msgTbl)
	gt.log("服务器推送玩家类型了========socketClient")
	if msgTbl then
		gt.playerData.playerType = msgTbl.m_playerType
		gt.log("服务器推送的玩家类型", gt.playerData.playerType, msgTbl.m_playerType)
		gt.dispatchEvent(gt.EventType.GC_ON_PLAYER_TYPE)
	end
	dump(msgTbl)	
end

function SocketClient:onLuckyDrawNumCallback(msgTbl)
	gt.log("推送抽奖次数")
	gt.playerData.luckyDrawNum = msgTbl.m_drawNum
end

return SocketClient


