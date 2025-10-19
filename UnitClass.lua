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

--both client() and server() functions are to ensure methods are being called from the correct environment
--mainly for debug purposes obv but assert will throw error and cease exec if it *is* the wrong env somehow
local function Client()
	local Caller, FunctionName

	--this is very similar to the server function below so i'll just explain for this one
	--we expect this function to be called by the objects methods, which in turn are called by the module that created the object, meaning we're at debug 'level' 3
	--debug.info(3, "s") is getting the path of the script that we care about, and we split it by period as it returns a path string split by periods
	--our Caller variable is then assigned to be the end of the path, so its just the script name
	--function name is debug level 2 as we only care about the method that called the function, not the function that called the method that called the function (mouthful)
	--i only do this when in studio for debugging purposes, and if in a normal game environment, use a generic 'client function called by the server' or vice versa message
	
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

--Unit.New is the function of the class that creates the object. an object can be made from the client or the server, but in practice will never be directly made on the client unless
--the client recieves a broadcast containing data for an object it doesnt yet have a local copy of (it knows this via the Identifier value which is a GUID),
--and in that case it will create an object with the same properties, as mentioned in the beginning explanation
function Unit.New(Owner: Player, Name: string, Attributes: Types.UnitAttributes)
	local UnitDefaults = UnitData[Name]

	if not UnitDefaults then
		return Utility.Debug(`Unit defaults not found, creation failed.`)
	end

	--for most of these properties that arent retrieved from a data module (UnitDefaults defined above), we will use either the Attributes table provided value, or the default
	--this means you could call Unit.New(Player, "UnitName", {Damage = 9999, WalkSpeed = 9999}), and make an extremely fast & heavy hitting kinda guy
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

	--__index metamethod lets us access _Properties table directly through self (self.HP instead of self._Properties.HP), while preserving method calls by checking if the key exists in the object first
	--__newindex metamethod handles property changes and triggers replication. by using this 'nested' _Properties table we're able to invoke the __newindex metamethod every time we
	--change a value, e.g Unit.WalkSpeed = 10, and with that we can add it to the _DirtyProperties table and flip the flag for a pending update & defer the broadcast changes method to run
	--and send this changed info to the client
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

				--if the environment is on the server when a property is changed, then we add the change to the aforementioned _DirtyProperties table and do the update as mentioned above
				if RunService:IsServer() and REPLICATED_PROPERTIES[Key] then
					Table._DirtyProperties[Key] = Value

					if not Table._PendingUpdate then
						Table._PendingUpdate = true
						--send properties to client
						task.defer(Table.BroadcastChanges, Table)
					end
				end
				
				--if the environment is on the client then we invoke the client specific PropertyChanged method with the key as an argument
				--this will allow the client to make changes as needed, for example when the .Position property is changed, we make the character model walk to the new position
				if RunService:IsClient() then
					Table:PropertyChanged(Key)
				end
			end
		end
	})

	Utility.Debug(`Ally unit created '{Properties.Name}' [{Properties.HP}/{Properties.MaxHP}] [UID {Properties.Identifier}]`)

	--if we're creating this object from the server, that means we still need it to be replicated by the clients, in which case we run the broadcast creation method below
	if RunService:IsServer() then
		self:BroadcastCreation()
	end

	return self
end

--sends all properties that need to be replicated to clients in one batch
--gets called via task.defer when properties change in the metamethod
function Unit:BroadcastChanges()
	Server()

	--here we're just using the next function to check if there are any key value pairs in the dirtyproperties table
	--this broadcast changes method shouldnt have been called otherwise, but better safe than sorry lol
	if not next(self._DirtyProperties) then return end

	--we send the type of signal as a string mainly for more descriptive debug prints on the client
	--although when an object is made on the server, we use the broadcast creation method, the UnitUpdate tag here doesn't exclusively mean
	--we wont ever create a unit from this signal, it just means we may do it in a different way, for instance: if a unit is JUST created, we might add some particle vfx when the model spawns
	--whereas if the client has just joined and recieves a UnitUpdate signal from the server, we might want to just immediately replicate object & its model with no VFX,
	--as its just catching up to the current server state.
	UnitManagementRemote:FireAllClients({
		Type = "UnitUpdate",
		Identifier = self._Properties.Identifier,
		OwnerUID = self._Properties.OwnerUID,
		Changes = self._DirtyProperties
	})

	table.clear(self._DirtyProperties)
	self._PendingUpdate = false
end

--tells clients to create their own version of this unit when a new object is made
--theyll make the same class and mirror properties
function Unit:BroadcastCreation()
	Server()

	local InitialState = {}

	--here we're making a cpy of the properties table to send to the client to replicate
	for Key, Value in self._Properties do
		InitialState[Key] = Value
	end

	--much like above we send the same information, including the GUID identifier to ensure we're syncing properties to the correct object
	UnitManagementRemote:FireAllClients({
		Type = "UnitCreated",
		Identifier = self._Properties.Identifier,
		OwnerUID = self._Properties.OwnerUID,
		InitialState = InitialState
	})
end

--self.Dead = true lol, this is just a flag thats used to validate whether a unit can take more damage, or move, etc.
function Unit:Kill()
	Server()

	Utility.Debug(`Ally unit '{self.Name}' [UID {self.Identifier}] Died`)
	self.Dead = true
end

--takes damage of Amount clamped to 0 lowest & runs kill method if health hits 0
function Unit:TakeDamage(Amount: number): number
	Server()
	--we use the DampenFactor property to get a RealDamage number, this is functionality that would allow for units of a certain class to 'buff' their teammates
	--and provide them with a lessened damage effect, explained in further detail in the ApplyDampen method below
	local RealDamage = Amount * self.DampenFactor

	--here we store PreviousHealth before it gets changed for the purposes of a debug print, and set the HP value to math.max between the hp-realdamage and 0
	--this will ensure our health never goes below 0, as it wouldn't make much sense to & would be ugly
	local PreviousHealth = self.HP
	self.HP = math.max(self.HP - RealDamage, 0)

	Utility.Debug(`'{self.Name}' [UID {self.Identifier}] HP {PreviousHealth} -> {self.HP}`)

	if self.HP == 0 then
		self:Kill()
	end
end

--unfinished, would take enemy and use the :TakeDamage method on it (enemy is a seperate class but has similar methods)
function Unit:Attack(Enemy: Types.EnemyUnit)
	Server()

	if self.Moving then
		return Utility.Debug(`{self.Name} [UID {self.Identifier}] is currently moving, but tried to attack.`)
	end
end

--some damage dampening function, would be used for ally ultimate ability sorta thing
function Unit:ApplyDampen(Amount: number, LengthOfTime: number)
	Server()
			
	--here we store the PreviousDampen value for debug purposes, and change the dampening factor in accordance to the amount argument given
	--we clamp the dampen factor between 0-1 as it will be used as a multiplier on damage, for example:
	--local Damage = 10 * self.DampenFactor
	--which makes any attacks weaker
	local PreviousDampen = self.DampenFactor
	self.DampenFactor = math.clamp(self.DampenFactor - Amount, 0, 1)

	Utility.Debug(`{self.Name} [UID {self.Identifier}] Dampen factor {PreviousDampen} -> {self.DampenFactor}`)

	--use the task lib delay function to remove the dampen factor after the specified period of time, also clamped to prevent anomalous values
	task.delay(LengthOfTime, function()
		PreviousDampen = self.DampenFactor
		self.DampenFactor = math.clamp(self.DampenFactor + Amount, 0, 1)
		
		Utility.Debug(`{self.Name} [UID {self.Identifier}] Dampen factor {PreviousDampen} -> {self.DampenFactor}`)
	end)
end

--client only, handles all the visual stuff
--creates the character model and ui elements based on object name
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

	--after validating all of the information regarding the object is correct, and we have a prefab model to clone, we begin replicating a model on the client that follows server properties
	--we immediately set the position of a new model to the self.Position CFrame, just so we're not walking from 0,0,0 to wherever when it's created

	self.Character = Prefab:Clone()

	if self.Position then
		self.Character:PivotTo(self.Position)
	end

	self.Character.Parent = workspace
	
	--here we set up the UI for the unit, this is the on-screen display with the units name & health shown to the player
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

	--we assign a self.UnitUI property on the client so we can refer to it in other methods, as opposed to finding the PlayerGui and using ActiveUnitsUI:FindFirstChild(self.Identifier) every time
	self.UnitUI = NewUnitUI

	return self.Character
end

--gets called automatically when properties change on client
--this is where all the rendering/animation stuff happens
function Unit:PropertyChanged(Property: string)
	Client()
	
	--animate hp bar using the tween service when health changes
	if Property == "HP" and self.UnitUI and self.UnitUI:FindFirstChild("HPBar") then
		--right here the value is clamped just for UI purposes, the element is using a UICorner, so if the size value is too low it goes from a circle to a flat pancake (thanks roblox)
		local HPScale = math.clamp((self.HP/self.MaxHP), .03, 1)
		TweenService:Create(self.UnitUI.HPBar.Container.Bar, TweenInfo.new(0.1, Enum.EasingStyle.Sine), {Size = UDim2.fromScale(HPScale, 1)}):Play()
		TweenService:Create(self.UnitUI.HPBar.Container.Marker, TweenInfo.new(0.1, Enum.EasingStyle.Sine), {Position = UDim2.fromScale(HPScale, 0.5)}):Play()
	end
	
	--grey out ui using the tween service when the unit is dead (taken damage that amounted the health to 0)
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

	--we set a self.Moving property to ensure other methods such as self:Attack(Enemy) aren't called during a movement, this is just a design preference
	self.Moving = true

	--here is just some boilerplate variable stuff, we use the :GetPivot() method of the character model to return a CFrame, and extrapolate the Position from this
	--we then get the target CFrame & Position in the same manor, and calculate the duration the movement should take, based on the self.WalkSpeed property & the distance from start->target in studs (magnitude)
	--the BOUNCE_AMPLITUDE & BOUNCE_FREQUENCY constants are made to control how the bouncing walk will behave, and do as they are described to by name
	local StartPosition = self.Character:GetPivot().Position
	local TargetCF: CFrame = self.Position
	local TargetPosition = TargetCF.Position
	local Duration = (TargetPosition - StartPosition).Magnitude / self.WalkSpeed
	local BOUNCE_FREQUENCY = 8
	local BOUNCE_AMPLITUDE = 0.5

	--here we define the Movement variable before assigning it the RBXScriptConnection so that we can disconnect from inside of the connection itself
	--this is used to disconnect and set to nil once the movement has ended & avoid a memory leak or incorrect behaviour
	--the Elapsed variable is set to 0, and then modified by DeltaTime in the runservice prerender connection to be a way we gauge how far the movement is progress wise to reaching the Duration variable above
	local Elapsed, Movement = 0, nil
	Movement = RunService.PreRender:Connect(function(DeltaTime: number)
		Elapsed += DeltaTime
		
		local Progress = math.min(Elapsed / Duration, 1)
		--we're using this delta time effected progress variable to lerp the position from Start -> End point to make sure frame rate does not effect how fast the character moves (since we're using a PreRender connection)
		local CurrentPosition = StartPosition:Lerp(TargetPosition, Progress)
		--the SideOffset uses Elapsed * BOUNCE_FREQUENCY to make the character tilt left & right as it walks using a sine wave which will move between -1 and 1 gradually
		--multiplying Elapsed by BOUNCE_FREQUENCY controls how fast the wobble occurs, and BOUNCE_AMPLITUDE controls how much it tilts
		local SideOffset = math.sin(Elapsed * BOUNCE_FREQUENCY) * BOUNCE_AMPLITUDE
		--UpOffset uses the same sine wave but doubled BOUNCE_FREQUENCY * 2 to make the character bob up/down twice as fast as it sways
		--we use math.abs to ensure the value is always positive, so the character doesnt end up bobbing/clipping into the floor (cus we're not using collision)
		local UpOffset = math.abs(math.sin(Elapsed * BOUNCE_FREQUENCY * 2)) * BOUNCE_AMPLITUDE * 0.3
		--LookAtCFrame orients the character to face the target position, and we rotate it -90 degrees on the Y axis to correct the models default facing direction
		--FinalCFrame then applies the SideOffset and UpOffset to the look-at position using CFrame.new, which moves the character relative to its facing direction
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

