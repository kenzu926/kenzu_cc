package dev.kenzu.ccbridge;

import appeng.api.networking.IGrid;
import appeng.api.networking.IGridNode;
import appeng.api.networking.IInWorldGridNodeHost;
import appeng.api.networking.energy.IEnergyService;
import appeng.api.networking.storage.IStorageService;
import appeng.api.storage.cells.StorageCell;
import appeng.api.storage.cells.IBasicCellItem;
import appeng.api.implementations.blockentities.IChestOrDrive;
import appeng.api.stacks.AEItemKey;
import appeng.api.stacks.AEKey;
import appeng.api.stacks.KeyCounter;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.api.peripheral.GenericPeripheral;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.block.entity.BlockEntity;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Adds read-only AE2 network information to grid-connected blocks such as a controller. */
public final class Ae2Peripheral implements GenericPeripheral {
    private static final String API_VERSION = "1.1.0";
    private static final int MAX_ITEM_ROWS = 8192;

    @Override
    public String id() {
        return KenzuCcBridge.MOD_ID + ":ae2";
    }

    @LuaFunction
    public final String getKenzuApiVersion(IInWorldGridNodeHost target) {
        return API_VERSION;
    }

    @LuaFunction(mainThread = true)
    public final boolean isConnected(IInWorldGridNodeHost target) {
        IGridNode node = findNode(target);
        return node != null && node.getGrid() != null && node.isActive();
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> getNetworkStats(IInWorldGridNodeHost target) throws LuaException {
        IGrid grid = requireGrid(target);
        int activeNodes = 0;
        int onlineNodes = 0;
        for (IGridNode node : grid.getNodes()) {
            if (node.isActive()) activeNodes++;
            if (node.isOnline()) onlineNodes++;
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("connected", true);
        result.put("nodeCount", grid.size());
        result.put("activeNodes", activeNodes);
        result.put("onlineNodes", onlineNodes);
        result.put("apiVersion", API_VERSION);
        return result;
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> getEnergyStats(IInWorldGridNodeHost target) throws LuaException {
        IEnergyService energy = requireGrid(target).getEnergyService();
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("powered", energy.isNetworkPowered());
        result.put("stored", energy.getStoredPower());
        result.put("capacity", energy.getMaxStoredPower());
        result.put("usage", energy.getAvgPowerUsage());
        result.put("input", energy.getAvgPowerInjection());
        result.put("idleUsage", energy.getIdlePowerUsage());
        return result;
    }

    @LuaFunction(mainThread = true)
    public final List<Map<String, Object>> getCells(IInWorldGridNodeHost target) throws LuaException {
        return collectCells(requireGrid(target));
    }

    @LuaFunction(mainThread = true)
    public final List<Map<String, Object>> listCells(IInWorldGridNodeHost target) throws LuaException {
        return collectCells(requireGrid(target));
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> getStorageStats(IInWorldGridNodeHost target) throws LuaException {
        List<Map<String, Object>> cells = collectCells(requireGrid(target));
        long total = 0;
        long used = 0;
        Set<String> drives = new java.util.HashSet<>();
        for (Map<String, Object> cell : cells) {
            total = saturatedAdd(total, number(cell.get("totalBytes")));
            used = saturatedAdd(used, number(cell.get("usedBytes")));
            drives.add(String.valueOf(cell.get("drive")));
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("total", total);
        result.put("used", used);
        result.put("available", Math.max(0, total - used));
        result.put("cellCount", cells.size());
        result.put("driveCount", drives.size());
        result.put("cells", cells);
        return result;
    }

    @LuaFunction(mainThread = true)
    public final long getTotalItemStorage(IInWorldGridNodeHost target) throws LuaException {
        return storageNumber(target, "totalBytes");
    }

    @LuaFunction(mainThread = true)
    public final long getMaxItemStorage(IInWorldGridNodeHost target) throws LuaException {
        return storageNumber(target, "totalBytes");
    }

    @LuaFunction(mainThread = true)
    public final long getUsedItemStorage(IInWorldGridNodeHost target) throws LuaException {
        return storageNumber(target, "usedBytes");
    }

    @LuaFunction(mainThread = true)
    public final long getAvailableItemStorage(IInWorldGridNodeHost target) throws LuaException {
        long total = storageNumber(target, "totalBytes");
        long used = storageNumber(target, "usedBytes");
        return Math.max(0, total - used);
    }

    @LuaFunction(mainThread = true)
    public final List<Map<String, Object>> listItems(IInWorldGridNodeHost target) throws LuaException {
        IStorageService storage = requireGrid(target).getStorageService();
        KeyCounter available = storage.getCachedInventory();
        List<Map<String, Object>> result = new ArrayList<>();

        for (Map.Entry<AEKey, Long> entry : available) {
            if (!(entry.getKey() instanceof AEItemKey key) || entry.getValue() <= 0) continue;
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("name", key.getId().toString());
            row.put("displayName", key.getDisplayName().getString());
            row.put("amount", entry.getValue());
            row.put("count", entry.getValue());
            result.add(row);
        }

        result.sort(Comparator.comparingLong(row -> -number(row.get("amount"))));
        if (result.size() > MAX_ITEM_ROWS) {
            return new ArrayList<>(result.subList(0, MAX_ITEM_ROWS));
        }
        return result;
    }

    private static long storageNumber(IInWorldGridNodeHost target, String key) throws LuaException {
        long value = 0;
        for (Map<String, Object> cell : collectCells(requireGrid(target))) {
            value = saturatedAdd(value, number(cell.get(key)));
        }
        return value;
    }

    private static List<Map<String, Object>> collectCells(IGrid grid) {
        List<Map<String, Object>> result = new ArrayList<>();
        Set<Object> visited = java.util.Collections.newSetFromMap(new IdentityHashMap<>());

        for (IGridNode node : grid.getNodes()) {
            Object owner = node.getOwner();
            if (!(owner instanceof IChestOrDrive drive) || !visited.add(owner)) continue;

            String driveName = describeOwner(owner);
            for (int slot = 0; slot < drive.getCellCount(); slot++) {
                Item item = drive.getCellItem(slot);
                if (item == null || item == net.minecraft.world.item.Items.AIR) continue;

                StorageCell inventory = drive.getOriginalCellInventory(slot);
                Map<String, Object> cell = new LinkedHashMap<>();
                ResourceLocation itemId = BuiltInRegistries.ITEM.getKey(item);
                cell.put("item", itemId.toString());
                cell.put("cellType", cellType(item));
                cell.put("state", drive.getCellStatus(slot).name());
                cell.put("drive", driveName);
                cell.put("slot", slot + 1);

                long totalBytes = reflectedLong(inventory, "getTotalBytes", basicCapacity(item));
                long usedBytes = reflectedLong(inventory, "getUsedBytes", 0);
                cell.put("totalBytes", totalBytes);
                cell.put("usedBytes", usedBytes);
                cell.put("availableBytes", Math.max(0, totalBytes - usedBytes));
                cell.put("bytesPerType", reflectedLong(inventory, "getBytesPerType", 0));
                cell.put("totalTypes", reflectedLong(inventory, "getTotalItemTypes", 0));
                cell.put("usedTypes", reflectedLong(inventory, "getStoredItemTypes", 0));
                cell.put("storedItems", reflectedLong(inventory, "getStoredItemCount", 0));
                cell.put("usedKnown", inventory != null);
                result.add(cell);
            }
        }
        return result;
    }

    private static long basicCapacity(Item item) {
        if (item instanceof IBasicCellItem basic) {
            return basic.getBytes(new ItemStack(item));
        }
        return 0;
    }

    private static String cellType(Item item) {
        if (item instanceof IBasicCellItem basic) {
            return basic.getKeyType().getId().toString();
        }
        return "unknown";
    }

    private static String describeOwner(Object owner) {
        if (owner instanceof BlockEntity blockEntity) {
            BlockPos pos = blockEntity.getBlockPos();
            String dimension = blockEntity.getLevel() == null
                ? "unknown"
                : blockEntity.getLevel().dimension().location().toString();
            return dimension + "@" + pos.getX() + "," + pos.getY() + "," + pos.getZ();
        }
        return owner.getClass().getSimpleName();
    }

    private static long reflectedLong(Object target, String methodName, long fallback) {
        if (target == null) return fallback;
        try {
            Method method = target.getClass().getMethod(methodName);
            method.trySetAccessible();
            Object value = method.invoke(target);
            return value instanceof Number number ? number.longValue() : fallback;
        } catch (NoSuchMethodException | IllegalAccessException | InvocationTargetException ignored) {
            return fallback;
        }
    }

    private static IGrid requireGrid(IInWorldGridNodeHost target) throws LuaException {
        IGridNode node = findNode(target);
        if (node == null || node.getGrid() == null) {
            throw new LuaException("AE2 grid is unavailable");
        }
        return node.getGrid();
    }

    private static IGridNode findNode(IInWorldGridNodeHost target) {
        for (Direction direction : Direction.values()) {
            IGridNode node = target.getGridNode(direction);
            if (node != null) return node;
        }
        return null;
    }

    private static long number(Object value) {
        return value instanceof Number number ? number.longValue() : 0;
    }

    private static long saturatedAdd(long left, long right) {
        if (right > 0 && left > Long.MAX_VALUE - right) return Long.MAX_VALUE;
        return left + right;
    }
}
