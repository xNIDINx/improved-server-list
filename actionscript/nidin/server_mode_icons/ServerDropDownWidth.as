package nidin.server_mode_icons
{
   import flash.display.DisplayObjectContainer;
   import flash.display.MovieClip;
   import flash.events.Event;
   import flash.geom.Point;
   import flash.utils.getQualifiedClassName;
   import net.wg.infrastructure.events.LifeCycleEvent;

   /** Sizes native controls through their logical width, never display scale. */
   public class ServerDropDownWidth
   {
      private static const SHADOW_WIDTH:Number = 6;
      private var row:MovieClip;
      private var popup:DisplayObjectContainer;
      private var measure:Function;
      private var changed:Function;
      private var provider:Object;
      private var online:Object = {};
      private var reserve:Number = 0;
      private var nativeWidth:Number;
      private var nativeMenuWidth:Number;
      private var appliedWidth:Number = NaN;
      private var appliedMenuWidth:Number = NaN;
      private var appliedPopupWidth:Number = NaN;
      private var nativePopupWidth:Number = NaN;
      private var lastPopupWidth:Number = NaN;
      private var plainRequirement:Number = NaN;
      private var onlineRequirement:Number = NaN;
      private var requiredMenuWidth:Number = NaN;
      private var dirty:Boolean = true;
      private var syncing:Boolean = false;
      private var disposed:Boolean = false;
      private var resizeUpdates:int = 0;

      public function ServerDropDownWidth(target:MovieClip, measurePopup:Function, onChanged:Function)
      {
         row = target;
         measure = measurePopup;
         changed = onChanged;
         nativeWidth = row.width;
         nativeMenuWidth = Number(Object(row).menuWidth);
         row.addEventListener(Event.EXIT_FRAME, onAfterFrame, false, -20000, true);
         row.addEventListener(Event.RENDER, onAfterFrame, false, -20000, true);
         row.addEventListener(Event.CHANGE, onDataChanged, false, -20000, true);
         watchProvider();
      }

      public function setContent(modes:Object, columnCount:int, values:Object) : void
      {
         reserve = ServerRowIcons.popupIconReserve(modes, columnCount);
         online = values != null ? values : {};
         dirty = true;
         refresh();
      }

      public function setPopup(value:DisplayObjectContainer) : void
      {
         if(popup === value)
         {
            return;
         }
         if(popup != null)
         {
            popup.removeEventListener(Event.REMOVED_FROM_STAGE, onPopupRemoved);
            popup.removeEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onPopupRemoved);
         }
         popup = value;
         appliedPopupWidth = nativePopupWidth = NaN;
         lastPopupWidth = popup != null ? popup.width : NaN;
         if(popup != null)
         {
            nativePopupWidth = popup.width - (!isNaN(appliedWidth) ? appliedWidth - nativeWidth : 0);
            popup.addEventListener(Event.REMOVED_FROM_STAGE, onPopupRemoved, false, 10000, true);
            popup.addEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onPopupRemoved, false, 10000, true);
         }
         dirty = true;
         refresh();
      }

      public function as_getDiagnostics() : Object
      {
         return {type: row != null ? getQualifiedClassName(row) : "", name: row != null ? row.name : "",
            nativeWidth: nativeWidth, width: row != null ? row.width : null,
            nativeMenuWidth: nativeMenuWidth, menuWidth: row != null ? Object(row).menuWidth : null,
            popupWidth: popup != null ? popup.width : null,
            requiredMenuWidth: isNaN(requiredMenuWidth) ? null : requiredMenuWidth,
            iconReserve: reserve, resizeUpdates: resizeUpdates};
      }

      public function dispose() : void
      {
         if(disposed)
         {
            return;
         }
         disposed = true;
         row.removeEventListener(Event.EXIT_FRAME, onAfterFrame);
         row.removeEventListener(Event.RENDER, onAfterFrame);
         row.removeEventListener(Event.CHANGE, onDataChanged);
         unwatchProvider();
         try
         {
            var anchor:Point = row.localToGlobal(new Point());
            if(popup != null && popup.stage != null && popup.width == appliedPopupWidth)
            {
               Object(popup).width = nativePopupWidth;
               Object(popup).validateNow();
            }
            if(row.width == appliedWidth)
            {
               Object(row).width = nativeWidth;
               Object(row).validateNow();
               layoutParent();
            }
            alignPopup(anchor);
            if(Number(Object(row).menuWidth) == appliedMenuWidth)
            {
               Object(row).menuWidth = nativeMenuWidth;
            }
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] width cleanup: " + error.message);
         }
         setPopup(null);
         row = null;
         measure = changed = null;
         online = null;
      }

      private function onPopupRemoved(event:Event) : void
      {
         if(event.target === popup)
         {
            setPopup(null);
         }
      }

      private function onDataChanged(event:Event) : void
      {
         if(event.target === row)
         {
            watchProvider();
            // CHANGE runs before native ServerDropDown finishes its layout.
            dirty = true;
         }
      }

      private function watchProvider() : void
      {
         var current:Object = row != null ? Object(row).dataProvider : null;
         if(current !== provider)
         {
            unwatchProvider();
            provider = current;
            if(provider != null)
            {
               provider.addEventListener("updateItem", onProviderUpdated, false, -20000, true);
            }
            dirty = true;
         }
      }

      private function unwatchProvider() : void
      {
         if(provider != null)
         {
            try
            {
               provider.removeEventListener("updateItem", onProviderUpdated);
            }
            catch(error:Error)
            {
               trace("[nidin.server_mode_icons] width provider cleanup: " + error.message);
            }
            provider = null;
         }
      }

      private function onProviderUpdated(event:Event) : void
      {
         watchProvider();
         if(event.currentTarget === provider)
         {
            dirty = true;
            refresh();
         }
      }

      private function onAfterFrame(event:Event) : void
      {
         refresh();
      }

      private function refresh() : void
      {
         if(disposed || syncing || row == null || row.stage == null)
         {
            return;
         }
         watchProvider();
         var width:Number = row.width;
         var menuWidth:Number = Number(Object(row).menuWidth);
         if(width != (isNaN(appliedWidth) ? nativeWidth : appliedWidth))
         {
            nativeWidth = width;
            appliedWidth = NaN;
            dirty = true;
         }
         var expectedMenu:Number = isNaN(appliedMenuWidth) ? nativeMenuWidth : appliedMenuWidth;
         if(menuWidth != expectedMenu && !(nativeMenuWidth < 0 && isNaN(appliedMenuWidth) && menuWidth == nativeWidth - SHADOW_WIDTH))
         {
            nativeMenuWidth = menuWidth;
            appliedMenuWidth = NaN;
            dirty = true;
         }
         if(popup != null && popup.width != lastPopupWidth)
         {
            nativePopupWidth = popup.width;
            appliedPopupWidth = NaN;
            dirty = true;
         }
         if(!dirty)
         {
            return;
         }
         syncing = true;
         try
         {
            var pendingMeasurements:Boolean = false;
            if(popup != null && popup.stage != null)
            {
               Object(popup).validateNow();
               var measurements:Object = measure != null ? measure(popup) : null;
               if(measurements != null)
               {
                  plainRequirement = Number(measurements.withoutOnline) - reserve;
                  onlineRequirement = Number(measurements.withOnline) - reserve;
               }
               else
               {
                  pendingMeasurements = isNaN(plainRequirement);
               }
            }
            var baseMenu:Number = nativeMenuWidth < 0 ? nativeWidth - SHADOW_WIDTH : nativeMenuWidth;
            var hasOnline:Boolean = false;
            if(provider != null)
            {
               for(var i:int = 0; i < Math.min(256, int(provider.length)); ++i)
               {
                  var item:Object = provider.requestItemAt(i);
                  if(item != null && item.data != null && online.hasOwnProperty(String(item.data)) && online[item.data] != null && String(online[item.data]) != "")
                  {
                     hasOnline = true;
                     break;
                  }
               }
            }
            var content:Number = hasOnline ? onlineRequirement : plainRequirement;
            requiredMenuWidth = reserve > 0 || hasOnline ? content + reserve : baseMenu;
            var targetMenu:Number = isNaN(requiredMenuWidth) ? baseMenu : Math.max(baseMenu, Math.ceil(requiredMenuWidth));
            var targetWidth:Number = nativeWidth + targetMenu - baseMenu;
            var resized:Boolean = false;
            var anchor:Point = row.localToGlobal(new Point());
            if(row.width != targetWidth)
            {
               Object(row).width = targetWidth;
               appliedWidth = targetWidth;
               Object(row).validateNow();
               layoutParent();
               resized = true;
            }
            if(Number(Object(row).menuWidth) != targetMenu)
            {
               Object(row).menuWidth = targetMenu;
               appliedMenuWidth = targetMenu;
            }
            if(popup != null && popup.stage != null && popup.width != targetMenu)
            {
               Object(popup).width = targetMenu;
               appliedPopupWidth = targetMenu;
               Object(popup).validateNow();
               resized = true;
            }
            if(resized)
            {
               alignPopup(anchor);
               ++resizeUpdates;
               if(changed != null)
               {
                  changed(row, popup);
               }
            }
            dirty = pendingMeasurements;
            lastPopupWidth = popup != null ? popup.width : NaN;
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] dynamic width: " + error.message);
         }
         finally
         {
            syncing = false;
         }
      }

      private function layoutParent() : void
      {
         // PrimeTime owns the joint label/dropdown centering. Other parents
         // keep their existing anchors and neighboring controls untouched.
         var owner:Object = row != null ? row.parent : null;
         if(owner != null && "serversDD" in owner && owner.serversDD === row &&
            "invalidateSize" in owner && "validateNow" in owner)
         {
            owner.invalidateSize();
            owner.validateNow();
         }
      }

      private function alignPopup(anchor:Point) : void
      {
         if(popup != null && popup.parent != null && row != null)
         {
            var before:Point = popup.parent.globalToLocal(anchor);
            var after:Point = popup.parent.globalToLocal(row.localToGlobal(new Point()));
            if(before.x != after.x || before.y != after.y)
            {
               popup.x += after.x - before.x;
               popup.y += after.y - before.y;
            }
         }
      }
   }
}
