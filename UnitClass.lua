--[[
	context alert!!
	this was the beginning of some code i was making for a unit class in a cookie run kingdom type game
	the basic premise is that an object is created on the server, and it uses metamethods to replicate itself
	on every client and mirror property changes on the fly
	the client automatically handles render stuff like movement or ui changes depending on the property changed

	server code would look something like this:
	local NewUnit = UnitClass.New(Player, "Donut", {})
	NewUnit.Position = CFrame.new(Vector3.new(5,0,10))
	NewUnit:TakeDamage(20)

	and the client would have made a unit with the same properties, began a walking animation to the specified cframe,
	and animated the hp bar to display the health change

	i didnt really know what else to submit so i hope this will suffice

	the code in the game i linked with this application is literally just:

	PlayerUnits.Allies[1] = UnitClass.New(Player, "Donut", {})
	PlayerUnits.Allies[2] = UnitClass.New(Player, "Cookie", {})
	PlayerUnits.Allies[3] = UnitClass.New(Player, "Popcorn", {})
	PlayerUnits.Allies[4] = UnitClass.New(Player, "Lollipop", {})
	
	task.delay(3, function()
		PlayerUnits.Allies[1].Position = CFrame.new(Vector3.new(20,0,20))
		PlayerUnits.Allies[2].Position = CFrame.new(Vector3.new(20,0,25))
		PlayerUnits.Allies[3].Position = CFrame.new(Vector3.new(20,0,30))
		PlayerUnits.Allies[4].Position = CFrame.new(Vector3.new(20,0,35))
		
		PlayerUnits.Allies[1]:TakeDamage(20)
		task.wait(1)
		PlayerUnits.Allies[1]:TakeDamage(30)
		task.wait(1)
		PlayerUnits.Allies[1]:TakeDamage(30)		
	end)
]]

local Unit = {}
local Data = script.Parent.Parent:WaitForChild("Data")
local Modules = script.Parent.Parent:WaitForChild("Modules")
local Assets = script.Parent.Parent:WaitForChild("Assets")

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UnitData = require(Data:WaitForChild("UnitData"))
local Types = require(Data:WaitForChild("Types"))
local Utility = require(Modules:WaitForChild("Utility"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UnitManagementRemote = Remotes:WaitForChild("UnitManagement")

local UnitsFolder = workspace:WaitForChild("Units")

--properties that get synced to clients when changed
--server tracks these in _DirtyProperties and batches them
local REPLICATED_PROPERTIES = {
	HP = true,
	Position = true,
	MaxHP = true,
	Damage = true,
	UltimateCooldown = true,
	DampenFactor = true,
	Moving = true,
	Dead = true
}

Unit.__index = Unit

local function Client()
	local Caller, FunctionName

	if RunService:IsStudio() then
		Caller = string.split(debug.info(3, "s"), ".")
		Caller = Caller[#Caller]
		FunctionName = debug.info(2, "n")
	end

	assert(RunService:IsClient(), `[{Caller or script.Name}]: Client function{FunctionName and " '"..FunctionName.."'" or "" } called by the server.`)
end

local function Server()
	local Caller, FunctionName

	if RunService:IsStudio() then
		Caller = string.split((debug.info(3, "s") or debug.info(2, "s")), ".")
		Caller = Caller[#Caller]
		FunctionName = debug.info(2, "n")
	end

	assert(RunService:IsServer(), `[{Caller or script.Name}]: Server function{FunctionName and " '"..FunctionName.."'" or "" } called by a client.`)
end

function Unit.New(Owner: Player, Name: string, Attributes: Types.UnitAttributes)
	local UnitDefaults = UnitData[Name]

	if not UnitDefaults then
		return Utility.Debug(`Unit defaults not found, creation failed.`)
	end

	local Properties = {
		Identifier = Attributes.Identifier or HttpService:GenerateGUID(false),
		Name = Name,
		OwnerUID = Owner.UserId,
		Position = Attributes.Position or CFrame.new(Vector3.new(0,0,0)),
		MaxHP = Attributes.MaxHP or UnitDefaults.MaxHP.Min,
		Damage = Attributes.Damage or UnitDefaults.Damage.Min,
		WalkSpeed = Attributes.WalkSpeed or 15,
		Ultimate = UnitDefaults.Ultimate,
		Texture = UnitDefaults.Texture,
		UltimateCooldown = Attributes.UltimateCooldown or 0,
		DampenFactor = Attributes.DampenFactor or 1,
		Dead = false
	}

	Properties.HP = Properties.MaxHP

	--metatable does the heavy lifting here
	--__index lets us access Properties table directly through self (self.HP instead of self._Properties.HP)
	--__newindex handles property changes and triggers replication
	local self = setmetatable({
		_Properties = Properties,
		_DirtyProperties = {}, --tracks what changed since last broadcast
		_PendingUpdate = false,
	}, {
		__index = function(Table, Key)
			if Unit[Key] then
				return Unit[Key]
			end
			return Properties[Key]
		end,
		__newindex = function(Table, Key, Value)
			if Properties[Key] ~= Value then
				Properties[Key] = Value

				--server side, track changes and schedule a broadcast
				--dirty properties accumulate until BroadcastChanges runs
				if RunService:IsServer() and REPLICATED_PROPERTIES[Key] then
					Table._DirtyProperties[Key] = Value

					if not Table._PendingUpdate then
						Table._PendingUpdate = true
						--send properties to client
						task.defer(Table.BroadcastChanges, Table)
					end
				end
				
				--client side, update visuals immediately when properties change
				if RunService:IsClient() then
					Table:PropertyChanged(Key)
				end
			end
		end
	})

	Utility.Debug(`Ally unit created '{Properties.Name}' [{Properties.HP}/{Properties.MaxHP}] [UID {Properties.Identifier}]`)

	if RunService:IsServer() then
		self:BroadcastCreation()
	end

	return self
end

--sends all properties that need to be replicated to clients in one batch
--gets called via task.defer when properties change in the metamethod
function Unit:BroadcastChanges()
	Server()

	if not next(self._DirtyProperties) then return end

	UnitManagementRemote:FireAllClients({
		Type = "UnitUpdate",
		Identifier = self._Properties.Identifier,
		OwnerUID = self._Properties.OwnerUID,
		Changes = self._DirtyProperties
	})

	table.clear(self._DirtyProperties)
	self._PendingUpdate = false
end

--tells clients to create their own version of this unit
--theyll make the same class and mirror properties
function Unit:BroadcastCreation()
	Server()

	local InitialState = {}

	for Key, Value in self._Properties do
		InitialState[Key] = Value
	end

	UnitManagementRemote:FireAllClients({
		Type = "UnitCreated",
		Identifier = self._Properties.Identifier,
		OwnerUID = self._Properties.OwnerUID,
		InitialState = InitialState
	})
end

function Unit:Kill()
	Server()

	Utility.Debug(`Ally unit '{self.Name}' [UID {self.Identifier}] Died`)
	self.Dead = true
end

function Unit:TakeDamage(Amount: number): number
	Server()
	local RealDamage = Amount * self.DampenFactor

	local PreviousHealth = self.HP
	self.HP = math.clamp(self.HP - RealDamage, 0, math.huge)

	Utility.Debug(`'{self.Name}' [UID {self.Identifier}] HP {PreviousHealth} -> {self.HP}`)

	if self.HP <= 0 then
		self:Kill()
	end
end

function Unit:Attack(Enemy: Types.EnemyUnit)
	Server()

	if self.Moving then
		return Utility.Debug(`{self.Name} [UID {self.Identifier}] is currently moving, but tried to attack.`)
	end
end

function Unit:ApplyDampen(Amount: number, LengthOfTime: number)
	Server()

	local PreviousDampen = self.DampenFactor
	self.DampenFactor = math.clamp(self.DampenFactor - Amount, 0, 1)

	Utility.Debug(`{self.Name} [UID {self.Identifier}] Dampen factor {PreviousDampen} -> {self.DampenFactor}`)

	task.delay(LengthOfTime, function()
		PreviousDampen = self.DampenFactor
		self.DampenFactor = math.clamp(self.DampenFactor + Amount, 0, 1)
		
		Utility.Debug(`{self.Name} [UID {self.Identifier}] Dampen factor {PreviousDampen} -> {self.DampenFactor}`)
	end)
end

--client only, handles all the visual stuff
--creates the character model and ui elements
function Unit:AddCharacter(Position: CFrame?): Model?
	Client()

	if self.Character then
		return Utility.Debug(`Character already initialized for {self.Name} [UID {self.Identifier}]`)
	end

	if not UnitsFolder:FindFirstChild(self.OwnerUID) then
		return Utility.Debug(`{self.Name} [UID {self.Identifier}] could not spawn, as Player {self.OwnerUID}'s folder doesn't exist`)
	end

	local Prefab: Model? = Assets.Units.Allies:FindFirstChild(self.Name)
	if not Prefab then
		return Utility.Debug(`Prefab '{self.Name}' not found.`)
	end

	self.Character = Prefab:Clone()

	if self.Position then
		self.Character:PivotTo(self.Position)
	end

	self.Character.Parent = workspace
	
	--setup the ui for this unit
	local Player = Players.LocalPlayer
	local PlayerGui = Player:WaitForChild("PlayerGui")
	local MainUI = PlayerGui:WaitForChild("MainUI")
	local ActiveUnitsUI = MainUI:WaitForChild("ActiveUnits")
	
	local HPScale = math.clamp((self.HP/self.MaxHP), .03, 1)
	local NewUnitUI = ActiveUnitsUI.ActiveUnit:Clone()
	NewUnitUI.Name = self.Identifier
	NewUnitUI.Visible = true
	NewUnitUI.HPBar.Container.Bar.Size = UDim2.fromScale(HPScale, 1)
	NewUnitUI.HPBar.Container.Marker.Position = UDim2.fromScale(HPScale, 0.5)
	NewUnitUI.NameLabel.Text = self.Name
	NewUnitUI.Parent = ActiveUnitsUI
	
	self.UnitUI = NewUnitUI

	return self.Character
end

--gets called automatically when properties change on client
--this is where all the rendering/animation stuff happens
function Unit:PropertyChanged(Property: string)
	Client()
	
	--animate hp bar when health changes
	if Property == "HP" and self.UnitUI and self.UnitUI:FindFirstChild("HPBar") then
		local HPScale = math.clamp((self.HP/self.MaxHP), .03, 1)
		TweenService:Create(self.UnitUI.HPBar.Container.Bar, TweenInfo.new(0.1, Enum.EasingStyle.Sine), {Size = UDim2.fromScale(HPScale, 1)}):Play()
		TweenService:Create(self.UnitUI.HPBar.Container.Marker, TweenInfo.new(0.1, Enum.EasingStyle.Sine), {Position = UDim2.fromScale(HPScale, 0.5)}):Play()
	end
	
	--grey out ui when dead
	if Property == "Dead" and self.Dead and self.UnitUI and self.UnitUI:FindFirstChild("HPBar") then
		TweenService:Create(self.UnitUI.HPBar, TweenInfo.new(0.3, Enum.EasingStyle.Sine), {ImageColor3 = Color3.fromRGB(127, 127, 127)}):Play()
		TweenService:Create(self.UnitUI.HPBar.Container.Marker, TweenInfo.new(0.3, Enum.EasingStyle.Sine), {ImageColor3 = Color3.fromRGB(127, 127, 127)}):Play()
		TweenService:Create(self.UnitUI.HPBar.Container.Bar, TweenInfo.new(0.3, Enum.EasingStyle.Sine), {BackgroundTransparency = 1}):Play()
		TweenService:Create(self.UnitUI.HPBar.Container.Bar.ImageLabel, TweenInfo.new(0.3, Enum.EasingStyle.Sine), {ImageTransparency = 1}):Play()
	end
	
	--start movement animation when position changes
	if Property == "Position" then
		self:Move()
	end
end

--client only, animates the unit moving to its new position
function Unit:Move(): boolean?
	Client()
	
	if not self.Character then
		return Utility.Debug(`{self._Properties.Name} [UID {self._Properties.Identifier}] has no character`)
	end
	
	self.Moving = true
	
	local StartPosition = self.Character:GetPivot().Position
	local TargetCF: CFrame = self.Position
	local TargetPosition = TargetCF.Position
	local Duration = (TargetPosition - StartPosition).Magnitude / self.WalkSpeed
	local BounceFrequency = 8
	local BounceAmplitude = 0.5
	
	local Elapsed, Movement = 0, nil
	Movement = RunService.PreRender:Connect(function(DeltaTime: number)
		Elapsed += DeltaTime
		
		local Progress = math.min(Elapsed / Duration, 1)
		local CurrentPosition = StartPosition:Lerp(TargetPosition, Progress)
		
		--walking bounce
		local SideOffset = math.sin(Elapsed * BounceFrequency) * BounceAmplitude
		local UpOffset = math.abs(math.sin(Elapsed * BounceFrequency * 2)) * BounceAmplitude * 0.3
		local LookAtCFrame = CFrame.lookAt(CurrentPosition, TargetPosition) * CFrame.Angles(0, math.rad(-90), 0)
		local FinalCFrame = LookAtCFrame * CFrame.new(SideOffset, UpOffset, 0)
		
		self.Character:PivotTo(FinalCFrame)
		
		if Progress >= 1 then
			self.Character:PivotTo(self.Position)
			self.Moving = false
			Movement:Disconnect()
			Movement = nil
		end
	end)
	
	return self.Moving
end

return Unit