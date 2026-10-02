package nidin.server_mode_icons
{
   import flash.display.DisplayObject;
   import flash.display.MovieClip;
   import flash.display.Stage;
   import flash.events.Event;
   import flash.text.TextField;
   import flash.utils.getQualifiedClassName;
   import net.wg.gui.components.controls.events.DropdownMenuEvent;
   import net.wg.infrastructure.events.LifeCycleEvent;
   import scaleform.clik.events.ListEvent;

   /** Aligns native header status icons without changing ping or label layout. */
   public class ServerDropDownStatus
   {
      private static const PING_RIGHT:int = 21;
      private static const PING_VISIBLE_PADDING:Number = 5.5;
      private static const STATUS_GAP:Number = 5;
      // Verified native event; ListDataProviderEvent is absent from the API SWC.
      private static const PROVIDER_UPDATE_ITEM:String = "updateItem";

      private var row:MovieClip;
      private var released:Function;
      private var openingStage:Stage;
      private var provider:Object;
      private var alertState:Object = {ref: null, nativeX: NaN, appliedX: NaN, offset: 4};
      private var blockState:Object = {ref: null, nativeX: NaN, appliedX: NaN, offset: 6};
      private var disposed:Boolean = false;
      private var syncing:Boolean = false;
      private var layoutUpdates:int = 0;
      private var syncUpdates:int = 0;

      public function ServerDropDownStatus(target:MovieClip, onReleased:Function)
      {
         row = target;
         released = onReleased;
         if(row == null)
         {
            return;
         }
         row.addEventListener(Event.EXIT_FRAME, onAfterFrame, false, -10000, true);
         row.addEventListener(Event.RENDER, onAfterFrame, false, -10000, true);
         row.addEventListener(Event.REMOVED_FROM_STAGE, onRemoved, false, 10000, true);
         row.addEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onRemoved, false, 10000, true);
         row.addEventListener(DropdownMenuEvent.CLOSE_DROP_DOWN, onDropdownClosed, false, -10000, true);
         row.addEventListener(ListEvent.INDEX_CHANGE, onDropdownIndexChanged, false, -10000, true);
         // Native populateText sends CHANGE before its status and layout work.
         row.addEventListener(Event.CHANGE, onDropdownDataChanged, false, -10000, true);
         // The root's priority-0 SHOW callback refreshes availability first.
         openingStage = App.stage;
         if(openingStage != null)
         {
            openingStage.addEventListener(DropdownMenuEvent.SHOW_DROP_DOWN, onDropdownOpened, false, -10000, true);
         }
         watchProvider();
      }

      public function as_getDiagnostics() : Object
      {
         var ping:TextField = row != null ? Object(row).pingTF as TextField : null;
         var alert:DisplayObject = row != null ? Object(row).alertIcon as DisplayObject : null;
         var block:DisplayObject = row != null ? Object(row).blockIcon as DisplayObject : null;
         return {
            type: row != null ? getQualifiedClassName(row) : "",
            pingRight: ping != null ? ping.x + ping.width : null,
            nativePingRight: row != null && ping != null ? int(row.width - ping.width - PING_RIGHT) + ping.width : null,
            alertVisible: alert != null && alert.visible,
            alertX: alert != null ? alert.x : null,
            alertRight: row != null && alert != null ? alert.getBounds(row).right : null,
            targetAlertRight: row != null ? alertRight(ping) : null,
            blockVisible: block != null && block.visible,
            blockX: block != null ? block.x : null,
            blockRight: row != null && block != null ? block.getBounds(row).right : null,
            targetBlockRight: row != null ? nativeStatusRight() : null,
            layoutUpdates: layoutUpdates,
            syncUpdates: syncUpdates
         };
      }

      public function refreshLayout() : void
      {
         if(!disposed && row != null && row.stage != null)
         {
            onAfterFrame(null);
         }
      }

      public function dispose() : void
      {
         if(disposed)
         {
            return;
         }
         disposed = true;
         var previous:MovieClip = row;
         var callback:Function = released;
         try
         {
            removeListener(row, Event.EXIT_FRAME, onAfterFrame);
            removeListener(row, Event.RENDER, onAfterFrame);
            removeListener(row, Event.REMOVED_FROM_STAGE, onRemoved);
            removeListener(row, LifeCycleEvent.ON_BEFORE_DISPOSE, onRemoved);
            removeListener(row, DropdownMenuEvent.CLOSE_DROP_DOWN, onDropdownClosed);
            removeListener(row, ListEvent.INDEX_CHANGE, onDropdownIndexChanged);
            removeListener(row, Event.CHANGE, onDropdownDataChanged);
            removeListener(openingStage, DropdownMenuEvent.SHOW_DROP_DOWN, onDropdownOpened);
            openingStage = null;
            unwatchProvider();
            restoreStatus(alertState);
            restoreStatus(blockState);
         }
         finally
         {
            row = null;
            released = null;
            alertState = blockState = null;
            if(callback != null)
            {
               callback(previous);
            }
         }
      }

      private function removeListener(target:Object, type:String, listener:Function) : void
      {
         if(target == null)
         {
            return;
         }
         try
         {
            target.removeEventListener(type, listener);
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] status listener cleanup: " + error.message);
         }
      }

      private function onRemoved(event:Event) : void
      {
         dispose();
      }

      private function onDropdownDataChanged(event:Event) : void
      {
         if(event.target == row)
         {
            watchProvider();
         }
      }

      private function onDropdownClosed(event:Event) : void
      {
         if(event.target == row)
         {
            settle(event);
         }
      }

      private function onDropdownOpened(event:Event) : void
      {
         if(event.target == row)
         {
            settle(event);
         }
      }

      private function onDropdownIndexChanged(event:Event) : void
      {
         if(disposed || row == null || event.target != row)
         {
            return;
         }
         watchProvider();
         // Open-menu selection creates another STATE invalidation in close().
         if(!Object(row).isOpen())
         {
            settle(event);
         }
      }

      private function watchProvider() : void
      {
         if(disposed || row == null)
         {
            return;
         }
         var current:Object = Object(row).dataProvider;
         if(current === provider)
         {
            return;
         }
         unwatchProvider();
         if(current != null)
         {
            // Native selected-item populateText/updateLayout runs at priority 0.
            current.addEventListener(PROVIDER_UPDATE_ITEM, onProviderItemUpdated, false, -10000, true);
            provider = current;
         }
      }

      private function unwatchProvider() : void
      {
         var previous:Object = provider;
         provider = null;
         removeListener(previous, PROVIDER_UPDATE_ITEM, onProviderItemUpdated);
      }

      private function onProviderItemUpdated(event:Event) : void
      {
         if(disposed || row == null)
         {
            return;
         }
         watchProvider();
         if(event.currentTarget !== provider || int(Object(event).index) != int(Object(row).selectedIndex))
         {
            return;
         }
         settle(event);
      }

      private function settle(event:Event) : void
      {
         if(disposed || row == null || row.stage == null || syncing)
         {
            return;
         }
         syncing = true;
         try
         {
            watchProvider();
            Object(row).validateNow();
            if(!disposed && row != null && row.stage != null)
            {
               onAfterFrame(event);
               ++syncUpdates;
            }
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] status synchronous refresh: " + error.message);
         }
         finally
         {
            syncing = false;
         }
      }

      private function onAfterFrame(event:Event) : void
      {
         if(disposed || row == null || row.stage == null)
         {
            return;
         }
         watchProvider();
         var ping:TextField = Object(row).pingTF as TextField;
         applyStatus(alertState, Object(row).alertIcon as DisplayObject, alertRight(ping));
         applyStatus(blockState, Object(row).blockIcon as DisplayObject, nativeStatusRight());
      }

      private function nativeStatusRight() : Number
      {
         return row.width - PING_RIGHT - PING_VISIBLE_PADDING;
      }

      private function alertRight(ping:TextField) : Number
      {
         if(ping != null && ping.visible)
         {
            return ping.getBounds(row).left - STATUS_GAP;
         }
         var waiting:DisplayObject = Object(row).waiting as DisplayObject;
         return waiting != null && waiting.visible ? waiting.getBounds(row).left - STATUS_GAP : nativeStatusRight();
      }

      private function applyStatus(state:Object, current:DisplayObject, targetRight:Number) : void
      {
         if(current !== state.ref)
         {
            // A timeline may replace the native icon. Restore only the old
            // object still carrying our own value, then capture the new one.
            restoreStatus(state);
            state.ref = current;
            state.nativeX = current != null ? current.x : NaN;
            state.appliedX = NaN;
         }
         if(current == null)
         {
            return;
         }
         if(!current.visible)
         {
            restoreStatus(state);
            return;
         }
         if(isNaN(state.appliedX) || current.x != state.appliedX)
         {
            state.nativeX = current.x;
         }
         var nextX:Number = current.x + targetRight - current.getBounds(row).right;
         if(Math.abs(current.x - nextX) >= 0.001)
         {
            current.x = nextX;
            state.appliedX = nextX;
            ++layoutUpdates;
         }
      }

      private function restoreStatus(state:Object) : void
      {
         if(state == null)
         {
            return;
         }
         try
         {
            var icon:DisplayObject = state.ref as DisplayObject;
            if(icon != null && !isNaN(state.appliedX) && icon.x == state.appliedX)
            {
               var label:TextField = row != null ? Object(row).textField as TextField : null;
               // Native layout truncates labelEnd before adding its offset.
               var nativeX:Number = label != null ? int(label.x + label.textWidth) + int(state.offset) : state.nativeX;
               if(!isNaN(nativeX) && icon.x != nativeX)
               {
                  icon.x = nativeX;
               }
            }
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] status layout cleanup: " + error.message);
         }
         finally
         {
            state.appliedX = NaN;
         }
      }
   }
}
