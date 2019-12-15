--[[
Basically copypaste of WoWUction.lua but with the difference that this ONLY
uses region prices
 --]]

if not AucAdvanced then
--  error("AucAdvanced not found!")
return end

-- register this file with Ace Libraries
local wowuction = select(2, ...)
wowuction = LibStub("AceAddon-3.0"):NewAddon(wowuction, "Auc-Stat-WoWuction_Region", "AceConsole-3.0")

local AceGUI = LibStub("AceGUI-3.0") -- load the AceGUI libraries

local libType, libName = "Stat", "WoWuction_Region"
local lib, parent, private = AucAdvanced.NewModule(libType, libName)

if not lib then return end
local aucPrint, decode, _, _, replicate, empty, get, set, default, debugPrint, fill, _TRANS = AucAdvanced.GetModuleLocals()
local GetFaction = AucAdvanced.GetFaction

lib.Processors = {}
lib.Processors.tooltip = function(callbackType, ...)
--  private.ProcessTooltip(...)
end

lib.Processors.config = function(callbackType, gui)
  if private.SetupConfigGui then
    private.SetupConfigGui(gui)
  end
end

lib.Processors.load = function(callbackType, addon)
  -- check that this is our load message, and that our OnLoad function still exists
  if addon == "auc-stat-wowuction" and private.OnLoad then
    private.OnLoad(addon)
  end
end

function lib.GetPrice(hyperlink, serverKey)
  if not get("stat.wowuction_region.enable") then return end
  local array = lib.GetPriceArray(hyperlink, serverKey)
  return array.price, array.mean, false, array.stddev
end

function lib.GetPriceColumns()
  return "DBMarket", "DBMarket", false, "Market Std Dev"
end

local array = {}
local seen

function lib.GetPriceArray(id, serverKey)
  if not get("stat.wowuction_region.enable") then return end
  seen = get("stat.wowuction_region.seen")
  wipe(array)

  array.seen = seen
  array.qty = seen

  array.price = lib.GetTSMValue("DBRegionMarketAvg", id)
  array.median = lib.GetTSMValue("DBRegionHistorical", id)
  array.min_buyout = lib.GetTSMValue("DBRegionMinBuyoutAvg", id)

  array.region_median = lib.GetTSMValue("DBGlobalHistorical", id)
  array.region_price = lib.GetTSMValue("DBGlobalMarketAvg", id)

  array.stddev = 0.01
  array.cstddev = 0.01
  array.region_stddev = 0.01
  array.region_cstddev = 0.01

  return array
end

function lib.GetTSMValue(priceString, item)
  return TSM_API.GetCustomPriceValue(priceString, TSM_API.ToItemString(item))
end

local bellCurve = AucAdvanced.API.GenerateBellCurve()
local weight, median, stddev
local pdfcache = {} -- FIXME: should be cleared when settings change
local n

function lib.GetItemPDF(hyperlink, serverKey)
  if not get("stat.wowuction_region.enable") then return end
--  if pdfcache[hyperlink] then
--    median = pdfcache[hyperlink]["median"]
--    stddev = pdfcache[hyperlink]["stddev"]
--  else
  n = get("stat.wowuction_region.n")
  local currWeight = get("stat.wowuction_region.projection") / 7 - 1
  -- 0 = -7 days = 0% current value, 100% 14-day median
  -- 1 = +0 days = 100% current value, 0% median
  -- 2 = +7 days = 200% current value, -100% median
  local array = lib.GetPriceArray(hyperlink, serverKey)
  local currPrice = array.price
  local median = array.median
  local currStddev = array.cstddev
  local stddev = array.stddev
  local projectedPrice, projectedStddev, regionProjectedPrice, regionProjectedStddev
  local regionCurrPrice = array.region_price
  local regionMedian = array.region_median
  local regionFallback = get("stat.wowuction_region.regionfallback")
  local confidence = get("stat.wowuction_region.confidence")
  local regionResidual = regionCurrStddev or regionStddev or nil
  local residual = currStddev or stddev or nil

  if regionStddev and regionCurrStddev then
    regionProjectedStddev = regionStddev * (1 - currWeight) + regionCurrStddev * currWeight
  else
    regionProjectedStddev = regionResidual
  end

  if currStddev and stddev then
    projectedStddev = stddev * (1 - currWeight) + currStddev * currWeight
  else
    projectedStddev = residual
    if not projectedStddev then
      if regionFallback and regionProjectedStddev then
        local n = get("stat.wowuction_region.n")
        projectedStddev = regionProjectedStddev * sqrt(n - 1) -- conservative estimate: region is a larger sample than realm
        residual = regionResidual * sqrt(n - 1)
      else
        return -- no stddev
      end
    end
  end

  if regionCurrPrice and regionMedian then
    regionProjectedPrice = regionCurrPrice * currWeight + regionMedian * (1 - currWeight)
  else
    regionProjectedPrice = regionCurrPrice or regionMedian or nil
  end

  if currPrice and median then
    local adjCurrWeight
    local regionAgreement = get("stat.wowuction_region.regionagreement")
    if regionCurrPrice and regionMedian and regionProjectedStddev and regionAgreement then
      -- estimate total variance and covariance of realm and region price time-series
      -- assumes uncorrelated residuals (probably errs on the side of smaller adjustment)
      local totalVariance = sqrt((residual^2 + (currPrice - median)^2/3)*(regionResidual^2 + (regionCurrPrice - median)^2/3))
      local covar = (regionCurrPrice - regionMedian)*(currPrice - median)/totalVariance
      adjCurrWeight = currWeight * (1 + covar * regionAgreement)
    else
      adjCurrWeight = currWeight
    end
    projectedPrice = currPrice * adjCurrWeight + median * (1 - adjCurrWeight)
  else
    projectedPrice = currPrice or median or nil
    if not projectedPrice then
      if regionFallback and regionProjectedPrice then
        projectedPrice = regionProjectedPrice
        confidence = get("stat.wowuction_region.fallbackconfidence")
      else
        return -- no price
      end
    end
  end

  local minErrorPct = get("stat.wowuction_region.minerrorpct")
  projectedStddev = math.max(projectedStddev, minErrorPct * projectedPrice) / confidence
  bellCurve:SetParameters(projectedPrice, projectedStddev)

  -- Calculate the lower and upper bounds as +/- 3 standard deviations
  local lower = projectedPrice - 3 * projectedStddev
  local upper = projectedPrice + 3 * projectedStddev

  return bellCurve, lower, upper
end

function lib.IsValidAlgorithm()
  if not get("stat.wowuction_region.enable") then return false end
  return true
end

function private.OnLoad(addon)
  default("stat.wowuction_region.enable", false)
  default("stat.wowuction_region.confidence", 5)
--  default("stat.wowuction_region.shockconfidence", 10)
  default("stat.wowuction_region.fallbackconfidence", 2)
  default("stat.wowuction_region.projection", -3.5)
  default("stat.wowuction_region.regionagreement", 1)
--  default("stat.wowuction_region.maxz", 2) -- because this parameter is used to effectively apply median-centered Bollinger Bands
  default("stat.wowuction_region.minerrorpct", 1)
--  default("stat.wowuction_region.detectpriceshocks", true)
--  default("stat.wowuction_region.detectstddevshocks", false)
  default("stat.wowuction_region.n", 492) -- 2 factions * 246 US realms as of 2012-09-17 (excludes Arena Pass)
  private.OnLoad = nil -- only run this function once
end

--~ function private.GetInfo(hyperlink, serverKey)

--~   local linkType, itemId, suffix, factor = decode(hyperlink)
--~   if (linkType ~= "item") then return end

--~   local dta = TSMAPI:GetItemValue(itemId, serverKey)
--~   return dta
--~ end

-- Localization via Auctioneer's Babylonian; from Auc-Advanced/CoreUtil.lua
local Babylonian = LibStub("Babylonian")
assert(Babylonian, "Babylonian is not installed")
local babylonian = Babylonian(AucStatwowuctionLocalizations)
_TRANS = function (stringKey)
  local locale = get("SelectedLocale")  -- locales are user choose-able
  -- translated key or english Key or Raw Key
  return babylonian(locale, stringKey) or babylonian[stringKey] or stringKey
end

function private.SetupConfigGui(gui)
  local id = gui:AddTab(lib.libName, lib.libType.." Modules")

  gui:AddHelp(id, "what wowuction",
    _TRANS('WOWUCTION_Help_wowuction'),
    _TRANS('WOWUCTION_Help_wowuctionAnswer')
  )

  -- All options in here will be duplicated in the tooltip frame
  local function addTooltipControls(id)
    -- FIXME: cache needs to clear when settings change
    gui:AddControl(id, "Header",     0,    _TRANS('WOWUCTION_Interface_wowuctionOptions'))
    gui:AddControl(id, "Note",       0, 1, nil, nil, " ")
    gui:AddControl(id, "Checkbox",   0, 1, "stat.wowuction_region.enable", _TRANS('WOWUCTION_Interface_Enablewowuction'))
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_Enablewowuction'))
    gui:AddControl(id, "WideSlider",  0, 1, "stat.wowuction_region.projection", -14, 14, 0.5, _TRANS('WOWUCTION_Interface_Projection') )
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_Projection'))
    gui:AddControl(id, "NumberBox", 0, 1, "stat.wowuction_region.maxz", 0, 1000, _TRANS('WOWUCTION_Interface_MaxZScore') )
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_MaxZScore'))
    gui:AddControl(id, "WideSlider",  0, 1, "stat.wowuction_region.minerrorpct", 0, 10, 0.5, _TRANS('WOWUCTION_Interface_MinErrorPercent') )
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_MinErrorPercent'))
    gui:AddControl(id, "Checkbox",   0, 1, "stat.wowuction_region.regionagreement", 0, 1, 0.1, _TRANS('WOWUCTION_Interface_RegionAgreement'))
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_RegionAgreement'))
    gui:AddControl(id, "NumberBox", 0, 1, "stat.wowuction_region.n", 0, 1000, _TRANS('WOWUCTION_Interface_N') )
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_N'))
    gui:AddControl(id, "WideSlider",  0, 1, "stat.wowuction_region.confidence", 1, 30, 1, _TRANS('WOWUCTION_Interface_Confidence') )
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_Confidence'))
    gui:AddControl(id, "WideSlider",  0, 1, "stat.wowuction_region.fallbackconfidence", 1, 30, 1, _TRANS('WOWUCTION_Interface_FallbackConfidence') )
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_FallbackConfidence'))
    gui:AddControl(id, "Checkbox",   0, 1, "stat.wowuction_region.regionfallback", _TRANS('WOWUCTION_Interface_RegionFallback'))
    gui:AddTip(id, _TRANS('WOWUCTION_HelpTooltip_RegionFallback'))

  end

  local tooltipID = AucAdvanced.Settings.Gui.tooltipID

  addTooltipControls(id)
  if tooltipID then addTooltipControls(tooltipID) end

  private.SetupConfigGui = nil -- only run once
end
