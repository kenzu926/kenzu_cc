package dev.kenzu.ccbridge;

import dan200.computercraft.api.ComputerCraftAPI;
import net.minecraftforge.fml.common.Mod;

@Mod(KenzuCcBridge.MOD_ID)
public final class KenzuCcBridge {
    public static final String MOD_ID = "kenzu_cc_bridge";

    public KenzuCcBridge() {
        ComputerCraftAPI.registerGenericSource(new Ae2Peripheral());
    }
}
