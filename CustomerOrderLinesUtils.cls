/**
 * CustomerOrderLinesUtils
 * -----------------------
 * Small utility helpers for Customer Order Lines:
 * - prependDeletedTag(): adds "[DEL]" to a Name unless already present.
 * - formatColName(): builds a deterministic Name based on OrderItemNumber or Id and the Product name when available.
 *
 * Notes:
 * - Safe-guards are included for null/blank names and absent Product2 relationship.
 */
public with sharing class CustomerOrderLinesUtils {
    
    public Static String prependDeletedTag(String originalName) {
        if (originalName == null || String.isBlank(originalName)) { return '[DEL]'; }
        if (originalName.startsWith('[DEL]')) { return originalName; }

        return '[DEL] ' + originalName;
    }

    public static String formatColName(OrderItem o){
        String key = (o.OrderItemNumber != null) ? o.OrderItemNumber : String.valueOf(o.Id);
        String prod = (o.Product2 != null && o.Product2.Name != null) ? '-' + o.Product2.Name : '';
        return 'COL-' + key + prod;
    }
}
