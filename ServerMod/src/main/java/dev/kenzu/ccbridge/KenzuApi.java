package dev.kenzu.ccbridge;

import dan200.computercraft.api.lua.IComputerSystem;
import dan200.computercraft.api.lua.ILuaAPI;
import dan200.computercraft.api.lua.LuaFunction;

import java.util.Map;

/** Global, server-authoritative API exposed to every ComputerCraft computer as {@code kenzu}. */
public final class KenzuApi implements ILuaAPI {
    private final IComputerSystem computer;
    private long planChatCursor;

    public KenzuApi(IComputerSystem computer) {
        this.computer = computer;
        this.planChatCursor = PlanChatBridge.latestId();
    }

    @Override
    public String[] getNames() {
        return new String[]{"kenzu"};
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> syncPlayerDifficulty() {
        return PlayerDifficultyPolicy.apply(computer.getLevel().getServer());
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> getPlayerDifficultyStatus() {
        return PlayerDifficultyPolicy.status(computer.getLevel().getServer());
    }

    @LuaFunction
    public final String getKenzuApiVersion() {
        return "1.2.0";
    }

    /** Returns new .plan chat commands as Unicode code points, once per computer. */
    @LuaFunction
    public final synchronized Map<String, Object> pollPlanChatMessages() {
        Map<String, Object> result = PlanChatBridge.messagesAfter(planChatCursor);
        Object latestId = result.get("latestId");
        if (latestId instanceof Number number) planChatCursor = number.longValue();
        return result;
    }
}
