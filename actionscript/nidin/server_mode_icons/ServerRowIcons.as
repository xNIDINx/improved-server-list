package nidin.server_mode_icons
{
   import flash.display.DisplayObject;
   import flash.display.MovieClip;
   import flash.display.Sprite;
   import flash.display.Stage;
   import flash.events.Event;
   import flash.events.MouseEvent;
   import flash.geom.Point;
   import flash.geom.Rectangle;
   import flash.text.TextField;
   import flash.text.TextFieldAutoSize;
   import flash.text.TextFormat;
   import flash.utils.getDefinitionByName;
   import flash.utils.getQualifiedClassName;
   import net.wg.gui.components.controls.Image;
   import net.wg.gui.components.controls.events.DropdownMenuEvent;
   import net.wg.infrastructure.events.LifeCycleEvent;
   import scaleform.clik.events.ListEvent;

   /** Updates only changed native server rows after CLIK draw and render. */
   public class ServerRowIcons
   {
      public static const STRIP_NAME:String = "nidinServerModeIcons";
      private static const ICON_SIZE:int = 20;
      // Frontline's visible 63/64 rim at 20 units, minus one screen pixel
      // at each end at scale2. All modes share this artwork height.
      private static const VISIBLE_ICON_HEIGHT:Number = 18.6875;
      private static const VISIBLE_GAP:Number = 5;
      // Relative to the native ping anchor, the popup border is 4 units farther
      // right, while the dropdown arrow starts 0.5 units earlier (RU 1.45).
      private static const LIST_BORDER_OFFSET:Number = 4;
      private static const DROPDOWN_BORDER_OFFSET:Number = -0.5;
      // Native header text has an extra half-unit of trailing transparent space.
      private static const DROPDOWN_PING_OVERHANG:Number = 0.5;
      private static const LABEL_GAP:int = 6;
      // Measured empty space after the native HTML ping indicator (RU 1.45).
      private static const PING_VISIBLE_RIGHT_INSET:Number = 5;
      // Verified ListDataProviderEvent.UPDATE_ITEM. Its class is deliberately
      // absent from the external API SWC; use its native event type directly.
      private static const PROVIDER_UPDATE_ITEM:String = "updateItem";
      private static var dropDownClass:Class;
      private static var rendererClass:Class;
      private static var tooltipOwner:ServerRowIcons;
      private static var tooltipDateTabStop:Number = NaN;

      private var row:MovieClip;
      private var servers:Object;
      private var released:Function;
      private var strip:Sprite;
      private var images:Array = [];
      private var iconKey:String = "";
      private var columns:int = 0;
      private var ownIconWidth:Number = 0;
      private var columnIconWidth:Number = 0;
      private var modesDirty:Boolean = true;
      private var isDropdown:Boolean;
      private var lastInput:Object;
      private var layoutUpdates:int = 0;
      private var imageLoads:int = 0;
      private var syncUpdates:int = 0;
      private var syncing:Boolean = false;
      private var provider:Object;
      private var openingStage:Stage;
      private var ping:TextField;
      private var label:TextField;
      private var waiting:DisplayObject;
      private var alert:DisplayObject;
      private var block:DisplayObject;
      private var statusMoves:Object = {};
      private var statusUpdates:int = 0;
      private var online:Object = {};
      private var onlineField:TextField;
      private var onlineLabel:TextField;
      private var onlineDirty:Boolean = false;
      private var onlineCandidateRight:Number = NaN;
      private var original:Object;
      private var applied:Object;
      private var disposed:Boolean = false;
      private var hoverIndex:int = -1;
      private var tooltipText:String = "";
      private var widthMeasure:TextField;
      private var widthMeasureKey:String = "";
      private var fullLabelWidth:Number = 0;
      private var onlineCapacityWidth:Number = 0;

      // The shared external API SWC intentionally does not export these three
      // lobby controls/VO classes. Resolve existing native instances, without
      // linking or embedding a replacement client class in this mod SWF.
      public static function isServerDropDown(value:Object) : Boolean
      {
         if(value == null)
         {
            return false;
         }
         if(dropDownClass == null)
         {
            dropDownClass = resolveNativeClass("net.wg.gui.components.common.serverStats.ServerDropDown");
         }
         // Timeline linkages such as ServerDropDownUI inherit the native
         // class. Match its whole hierarchy, like a compile-time `is` check.
         return dropDownClass != null && value is dropDownClass;
      }

      public static function isServerRenderer(value:Object) : Boolean
      {
         if(value == null)
         {
            return false;
         }
         if(rendererClass == null)
         {
            rendererClass = resolveNativeClass("net.wg.gui.components.controls.ServerRenderer");
         }
         return rendererClass != null && value is rendererClass;
      }

      private static function resolveNativeClass(name:String) : Class
      {
         try
         {
            return getDefinitionByName(name) as Class;
         }
         catch(error:Error)
         {
            // A GUI library may not be loaded yet; retry on the next native
            // view/dropdown event rather than caching the failed lookup.
         }
         return null;
      }

      public function ServerRowIcons(target:MovieClip, modes:Object, columnCount:int, onReleased:Function)
      {
         row = target;
         servers = modes;
         columns = Math.max(0, Math.min(6, columnCount));
         columnIconWidth = measureColumnWidth(modes, columns);
         isDropdown = isServerDropDown(target);
         released = onReleased;
         strip = new Sprite();
         strip.name = STRIP_NAME;
         strip.mouseEnabled = false;
         strip.mouseChildren = false;
         strip.tabEnabled = false;
         strip.tabChildren = false;
         // Native validation can run on ENTER_FRAME or later on RENDER.
         // Never undo the decoration between frames; repaint only values
         // overwritten by native layout, after its priority-0 handlers.
         row.addEventListener(Event.EXIT_FRAME, onAfterFrame, false, -10000, true);
         row.addEventListener(Event.RENDER, onAfterFrame, false, -10000, true);
         row.addEventListener(Event.REMOVED_FROM_STAGE, onRemoved, false, 10000, true);
         row.addEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onRemoved, false, 10000, true);
         if(!isDropdown)
         {
            // Images remain mouse-disabled. Observe the native row instead,
            // after its tooltip handlers, without intercepting selection.
            row.addEventListener(MouseEvent.MOUSE_MOVE, onIconMouseMove, false, -10000, true);
            row.addEventListener(MouseEvent.MOUSE_OVER, onIconMouseMove, false, -10000, true);
            row.addEventListener(MouseEvent.ROLL_OVER, onIconRollOver, false, -10000, true);
            row.addEventListener(MouseEvent.ROLL_OUT, onIconRollOut, false, -10000, true);
            row.addEventListener(MouseEvent.MOUSE_DOWN, onIconRollOut, false, -10000, true);
         }
         if(isDropdown)
         {
            // The bridge refreshes opening-time availability on Stage at 0.
            // Settle this bubbling SHOW after that refresh and native setup.
            openingStage = App.stage;
            if(openingStage != null)
            {
               openingStage.addEventListener(DropdownMenuEvent.SHOW_DROP_DOWN, onDropdownOpened, false, -10000, true);
            }
            row.addEventListener(DropdownMenuEvent.CLOSE_DROP_DOWN, onDropdownClosed, false, -10000, true);
            row.addEventListener(ListEvent.INDEX_CHANGE, onDropdownIndexChanged, false, -10000, true);
            // CHANGE is sent from inside native populateText, before layout.
            // Rebind only; never validate or decorate in that early callback.
            row.addEventListener(Event.CHANGE, onDropdownDataChanged, false, -10000, true);
            watchProvider();
         }
      }

      public function setModes(modes:Object, columnCount:int) : void
      {
         servers = modes;
         watchProvider();
         var nextColumns:int = Math.max(0, Math.min(6, columnCount));
         var nextWidth:Number = measureColumnWidth(modes, nextColumns);
         if(nextColumns != columns || nextWidth != columnIconWidth || modeKey(modesFor(getServer())) != iconKey)
         {
            modesDirty = true;
         }
         columns = nextColumns;
         columnIconWidth = nextWidth;
      }

      public function setOnline(values:Object) : void
      {
         online = values != null ? values : {};
         var text:String = onlineFor(getServer());
         if(text != (onlineField != null ? onlineField.text : ""))
         {
            onlineDirty = true;
         }
      }

      public function as_getDiagnostics() : Object
      {
         var ready:int = 0;
         var alphas:Array = [];
         var bounds:Array = [];
         for each(var image:Image in images)
         {
            alphas.push(image.alpha);
            if(row != null && row.stage != null && image.ready)
            {
               var visibleArea:Rectangle = visibleIconBounds(image);
               var topLeft:Point = strip.localToGlobal(visibleArea.topLeft);
               var bottomRight:Point = strip.localToGlobal(visibleArea.bottomRight);
               var area:Rectangle = new Rectangle(topLeft.x, topLeft.y,
                  bottomRight.x - topLeft.x, bottomRight.y - topLeft.y);
               bounds.push({index: bounds.length, x: area.x, y: area.y,
                  width: area.width, height: area.height,
                  centerX: area.x + area.width / 2, centerY: area.y + area.height / 2});
            }
            else
            {
               bounds.push(null);
            }
            if(image.ready)
            {
               ++ready;
            }
         }
         return {
            type: row != null ? getQualifiedClassName(row) : "",
            rowWidth: row != null ? row.width : 0,
            rowHeight: row != null ? row.height : 0,
            visibleIconHeight: VISIBLE_ICON_HEIGHT,
            pingX: ping != null ? ping.x : null,
            pingRight: ping != null ? ping.x + ping.width : null,
            targetPingX: row != null && ping != null ? nativePingX() - reserveWidth() : null,
            columns: columns, reservedColumns: reservedColumns(), reserve: reserveWidth(),
            imageCount: images.length, readyImages: ready,
            ownIconWidth: ownIconWidth, columnIconWidth: columnIconWidth,
            alertVisible: alert != null && alert.visible,
            alertX: alert != null ? alert.x : null,
            alertRight: alert != null ? alert.getBounds(row).right : null,
            blockVisible: block != null && block.visible,
            blockX: block != null ? block.x : null,
            blockRight: block != null ? block.getBounds(row).right : null,
            targetStatusRight: row != null && ping != null ? statusRight() : null,
            statusUpdates: statusUpdates,
            onlineText: onlineField != null && onlineField.visible ? onlineField.text : "",
            onlineX: onlineField != null && onlineField.visible ? onlineField.x : null,
            onlineRight: onlineField != null && onlineField.visible ? onlineField.x + onlineField.width : null,
            onlineCandidateRight: isNaN(onlineCandidateRight) ? null : onlineCandidateRight,
            pingVisibleLeft: ping != null && ping.visible ? visiblePingLeft() : null,
            onlineVisible: onlineField != null && onlineField.visible,
            hoverIndex: hoverIndex, tooltipVisible: tooltipOwner === this,
            tooltipText: tooltipText, iconBounds: bounds,
            iconAlphas: alphas,
            layoutUpdates: layoutUpdates, imageLoads: imageLoads, syncUpdates: syncUpdates
         };
      }

      /** Absolute minimum row width, independent of its current expansion. */
      public function requiredWidth(includeOnline:Boolean) : Number
      {
         if(disposed || row == null)
         {
            return NaN;
         }
         var field:TextField = Object(row).textField as TextField;
         var pingField:TextField = Object(row).pingTF as TextField;
         var data:Object = getServer();
         if(field == null || pingField == null || data == null)
         {
            return NaN;
         }
         var text:String = Object(row).label != null ? String(Object(row).label) : String(data.label);
         var format:TextFormat = field.getTextFormat();
         var onlineText:String = onlineFor(data);
         var key:String = text + "\n" + onlineText + "\n" + format.font + ":" + format.size + ":" + format.bold + ":" + field.embedFonts;
         if(widthMeasure == null || key != widthMeasureKey)
         {
            if(widthMeasure == null)
            {
               widthMeasure = new TextField();
               widthMeasure.autoSize = TextFieldAutoSize.LEFT;
               widthMeasure.wordWrap = false;
               widthMeasure.multiline = false;
            }
            widthMeasure.embedFonts = field.embedFonts;
            widthMeasure.defaultTextFormat = format;
            widthMeasure.text = text;
            fullLabelWidth = widthMeasure.textWidth;
            format.size = format.size != null ? Math.max(8, Number(format.size) - 2) : 12;
            widthMeasure.defaultTextFormat = format;
            // Reserve a formatted five-digit count when online is enabled.
            widthMeasure.text = "99 999";
            onlineCapacityWidth = widthMeasure.width;
            if(onlineText != "")
            {
               widthMeasure.text = onlineText;
               onlineCapacityWidth = Math.max(onlineCapacityWidth, widthMeasure.width);
            }
            widthMeasureKey = key;
         }
         var contentRight:Number = field.x + fullLabelWidth;
         if(includeOnline && data.data != null && String(data.data) != "")
         {
            contentRight = Math.ceil(contentRight + LABEL_GAP) + onlineCapacityWidth;
         }
         var reserve:Number = reserveWidth();
         var limit:Number = row.width - 2 - reserve - PING_VISIBLE_RIGHT_INSET;
         if(pingField.visible)
         {
            // The old decoration may still have the previous icon reserve.
            // Keep its text inset, but calculate the new absolute anchor.
            ping = pingField;
            limit = nativePingX() - reserve + visiblePingLeft() - pingField.x;
         }
         else
         {
            var wait:DisplayObject = Object(row).waiting as DisplayObject;
            if(wait != null && wait.visible)
            {
               limit = row.width - (wait.width >> 1) - 5 - reserve + wait.getBounds(row).left - wait.x;
            }
         }
         for each(var statusName:String in ["alertIcon", "blockIcon"])
         {
            var status:DisplayObject = Object(row)[statusName] as DisplayObject;
            if(status != null && status.visible)
            {
               if(pingField.visible || (Object(row).waiting != null && Object(row).waiting.visible) || statusName == "blockIcon" && Object(row).alertIcon != null && Object(row).alertIcon.visible)
               {
                  limit -= VISIBLE_GAP;
               }
               limit -= status.getBounds(row).width;
            }
         }
         var contentMinimum:Number = row.width + contentRight + LABEL_GAP - limit;
         // Native truncation also needs room inside the label's own field.
         var labelMinimum:Number = fullLabelWidth + 4 + field.x + 60;
         var fieldLimit:Number = pingField.visible ? Math.min(nativePingX() - reserve, limit) : limit;
         labelMinimum = Math.max(labelMinimum, row.width + field.x + fullLabelWidth + 4 + LABEL_GAP - fieldLimit);
         return Math.ceil(Math.max(contentMinimum, labelMinimum));
      }

      public function refreshLayout() : void
      {
         if(!disposed && row != null && row.stage != null)
         {
            Object(row).validateNow();
            if(!disposed && row != null && row.stage != null)
            {
               onAfterFrame(null);
            }
         }
      }

      public static function popupIconReserve(modes:Object, columnCount:int) : Number
      {
         var count:int = Math.max(0, Math.min(6, columnCount));
         return count > 0 ? measureColumnWidth(modes, count) + VISIBLE_GAP - LIST_BORDER_OFFSET : 0;
      }

      public function dispose() : void
      {
         if(disposed)
         {
            return;
         }
         disposed = true;
         hideIconTooltip();
         row.removeEventListener(Event.EXIT_FRAME, onAfterFrame);
         row.removeEventListener(Event.RENDER, onAfterFrame);
         row.removeEventListener(Event.REMOVED_FROM_STAGE, onRemoved);
         row.removeEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onRemoved);
         row.removeEventListener(MouseEvent.MOUSE_MOVE, onIconMouseMove);
         row.removeEventListener(MouseEvent.MOUSE_OVER, onIconMouseMove);
         row.removeEventListener(MouseEvent.ROLL_OVER, onIconRollOver);
         row.removeEventListener(MouseEvent.ROLL_OUT, onIconRollOut);
         row.removeEventListener(MouseEvent.MOUSE_DOWN, onIconRollOut);
         if(isDropdown)
         {
            if(openingStage != null)
            {
               openingStage.removeEventListener(DropdownMenuEvent.SHOW_DROP_DOWN, onDropdownOpened);
               openingStage = null;
            }
            row.removeEventListener(DropdownMenuEvent.CLOSE_DROP_DOWN, onDropdownClosed);
            row.removeEventListener(ListEvent.INDEX_CHANGE, onDropdownIndexChanged);
            row.removeEventListener(Event.CHANGE, onDropdownDataChanged);
         }
         unwatchProvider();
         try
         {
            restoreLayout();
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] layout cleanup: " + error.message);
         }
         restoreStatus("alertIcon", 4);
         restoreStatus("blockIcon", 6);
         clearOnline();
         clearImages();
         if(strip.parent != null)
         {
            strip.parent.removeChild(strip);
         }
         var previous:MovieClip = row;
         var callback:Function = released;
         row = null;
         strip = null;
         servers = null;
         online = null;
         released = null;
         ping = label = null;
         waiting = alert = block = null;
         original = applied = lastInput = null;
         widthMeasure = null;
         widthMeasureKey = "";
         if(callback != null)
         {
            callback(previous);
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
         // An open menu still calls close() after INDEX_CHANGE; that creates
         // a second native STATE invalidation. Wait for its CLOSE event.
         if(!Object(row).isOpen())
         {
            settle(event);
         }
      }

      private function watchProvider() : void
      {
         if(!isDropdown || disposed || row == null)
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
            // Native ServerDropDown listens at priority 0. Its synchronous
            // populateText/updateLayout is complete before this callback.
            current.addEventListener(PROVIDER_UPDATE_ITEM, onProviderItemUpdated, false, -10000, true);
            provider = current;
         }
      }

      private function unwatchProvider() : void
      {
         var previous:Object = provider;
         provider = null;
         if(previous != null)
         {
            try
            {
               previous.removeEventListener(PROVIDER_UPDATE_ITEM, onProviderItemUpdated);
            }
            catch(error:Error)
            {
               trace("[nidin.server_mode_icons] provider cleanup: " + error.message);
            }
         }
      }

      private function onProviderItemUpdated(event:Event) : void
      {
         if(disposed || row == null)
         {
            return;
         }
         watchProvider();
         // A dispatched update may belong to an old provider replaced by an
         // earlier listener. Never process that stale update after rebinding.
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
            // Native callbacks can dispose the row during synchronous draw.
            if(!disposed && row != null && row.stage != null)
            {
               onAfterFrame(event);
               ++syncUpdates;
            }
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] synchronous refresh: " + error.message);
         }
         finally
         {
            syncing = false;
         }
      }

      private function getServer() : Object
      {
         if(row == null)
         {
            return null;
         }
         var dropdown:Object = isDropdown ? Object(row) : null;
         if(dropdown != null)
         {
            var index:int = dropdown.selectedIndex;
            if(dropdown.dataProvider != null && index >= 0 && index < dropdown.dataProvider.length)
            {
               return dropdown.dataProvider.requestItemAt(index);
            }
            return null;
         }
         return Object(row).data;
      }

      private function onAfterFrame(event:Event) : void
      {
         if(disposed || row == null || row.stage == null)
         {
            return;
         }
         watchProvider();
         var data:Object = getServer();
         var valid:Array = modesFor(data);
         var key:String = modeKey(valid);
         var iconsChanged:Boolean = key != iconKey || images.length != valid.length;
         if(iconsChanged)
         {
            updateImages(valid);
            iconKey = key;
         }
         var nativePing:TextField = Object(row).pingTF as TextField;
         var nativeLabel:TextField = Object(row).textField as TextField;
         var nativeWaiting:DisplayObject = Object(row).waiting as DisplayObject;
         if(nativePing == null || nativeLabel == null || nativeWaiting == null)
         {
            return;
         }
         ping = nativePing;
         label = nativeLabel;
         waiting = nativeWaiting;
         alert = Object(row).alertIcon as DisplayObject;
         block = Object(row).blockIcon as DisplayObject;
         if(reservedColumns() == 0)
         {
            restoreLayout();
            if(strip.visible)
            {
               strip.visible = false;
            }
            updateStatusLayout();
            updateOnlineLayout(data);
            modesDirty = false;
            hideIconTooltip();
            return;
         }
         var current:Object = snapshot();
         var input:Object = {
            width: row.width, height: row.height,
            pingWidth: ping.width, waitingWidth: waiting.width, labelX: label.x,
            data: dataSignature(data), visible: row.visible,
            pingVisible: ping.visible, waitingVisible: waiting.visible,
            alertVisible: alert != null && alert.visible,
            blockVisible: block != null && block.visible
         };
         var nativeChanged:Boolean = differs(current, applied);
         if(!modesDirty && !onlineDirty && !iconsChanged && !nativeChanged && !differs(input, lastInput) && strip.parent == row)
         {
            if(tooltipOwner === this)
            {
               updateIconTooltip(valid, false);
            }
            return;
         }
         captureNative(current);
         var reserve:Number = reserveWidth();
         var right:Number = row.width - (isDropdown ? 21 : 2);
         var targetPing:Number = nativePingX() - reserve;
         var targetWaiting:Number = nativeWaitingX() - reserve;
         setX(ping, targetPing);
         setX(waiting, targetWaiting);
         updateStatusLayout();
         var leftLimit:Number = ping.visible ? targetPing :
            (waiting.visible ? targetWaiting - (waiting.width >> 1) : right - reserve);
         if(alert != null && alert.visible)
         {
            leftLimit = Math.min(leftLimit, alert.getBounds(row).left);
         }
         if(block != null && block.visible)
         {
            leftLimit = Math.min(leftLimit, block.getBounds(row).left);
         }
         var targetLabelWidth:Number = Math.max(10, Math.min(original.labelWidth,
            leftLimit - label.x - LABEL_GAP));
         var labelChanged:Boolean = label.width != targetLabelWidth ||
            lastInput == null || input.data != lastInput.data ||
            applied == null || current.labelHtml != applied.labelHtml;
         if(label.width != targetLabelWidth)
         {
            label.width = targetLabelWidth;
         }
         if(labelChanged && data != null)
         {
            App.utils.commons.truncateTextFieldText(label, data.label);
         }
         setX(strip, right - reservedIconWidth());
         var targetY:Number = (row.height - VISIBLE_ICON_HEIGHT) / 2;
         if(strip.y != targetY)
         {
            strip.y = targetY;
         }
         // Match native inactive-server rendering without touching haveAccess,
         // disabled state, ping visibility or the standard server tooltip.
         var targetAlpha:Number = data != null && data.enabled ? 1 : 0.6;
         if(strip.alpha != targetAlpha)
         {
            strip.alpha = targetAlpha;
         }
         var targetVisible:Boolean = valid.length > 0 && row.visible;
         if(strip.visible != targetVisible)
         {
            strip.visible = targetVisible;
         }
         if(strip.parent != row)
         {
            row.addChild(strip);
         }
         updateOnlineLayout(data);
         applied = snapshot();
         lastInput = input;
         modesDirty = false;
         ++layoutUpdates;
         if(tooltipOwner === this)
         {
            // Native setData/draw may have hidden its previous row tooltip.
            updateIconTooltip(valid, nativeChanged || iconsChanged);
         }
      }

      private function onIconMouseMove(event:MouseEvent) : void
      {
         updateIconTooltip(modesFor(getServer()), false);
      }

      private function onIconRollOver(event:MouseEvent) : void
      {
         // ROLL_OVER follows the native row's own tooltip listener. Reassert
         // our tooltip even if MOUSE_OVER already selected the same image.
         updateIconTooltip(modesFor(getServer()), true);
      }

      private function onIconRollOut(event:MouseEvent) : void
      {
         hideIconTooltip();
      }

      private function updateIconTooltip(modes:Array, force:Boolean) : void
      {
         if(disposed || isDropdown || row == null || row.stage == null ||
            !row.visible || strip == null || strip.parent != row || !strip.visible)
         {
            hideIconTooltip();
            return;
         }
         var point:Point = new Point(strip.mouseX, strip.mouseY);
         var index:int = -1;
         for(var i:int = 0; i < images.length && i < modes.length; ++i)
         {
            var image:Image = images[i] as Image;
            if(image != null && image.ready && image.visible && visibleIconBounds(image).containsPoint(point))
            {
               index = i;
               break;
            }
         }
         var marker:Object = index >= 0 ? modes[index] : null;
         var title:String = marker != null && marker.tooltipTitle != null ? String(marker.tooltipTitle) : "";
         var body:String = marker != null && marker.tooltipBody != null ? String(marker.tooltipBody) : "";
         if(index < 0 || (title == "" && body == ""))
         {
            var restoreNative:Boolean = tooltipOwner === this;
            hideIconTooltip();
            if(restoreNative && !disposed && row != null && row.stage != null &&
               row.hitTestPoint(row.stage.mouseX, row.stage.mouseY, false))
            {
               showNativeTooltip();
            }
            return;
         }
         var text:String = "{HEADER}" + escapeTooltip(title) + "{/HEADER}{BODY}" +
            formatTooltipBody(body) + "{/BODY}";
         if(!force && tooltipOwner === this && hoverIndex == index && tooltipText == text)
         {
            return;
         }
         if(tooltipOwner != null && tooltipOwner !== this)
         {
            // A later disposal/ROLL_OUT of that row must not hide this one.
            tooltipOwner.hoverIndex = -1;
            tooltipOwner.tooltipText = "";
         }
         tooltipOwner = this;
         hoverIndex = index;
         tooltipText = text;
         try
         {
            App.toolTipMgr.showComplex(text);
         }
         catch(error:Error)
         {
            hideIconTooltip();
            trace("[nidin.server_mode_icons] mode tooltip: " + error.message);
         }
      }

      private static function escapeTooltip(value:String) : String
      {
         return value.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;")
            .split("\r\n").join("\n").split("\r").join("\n").split("\n").join("<br/>");
      }

      private static function formatTooltipBody(value:String) : String
      {
         var lines:Array = value.split("\r\n").join("\n").split("\r").join("\n").split("\n");
         for(var i:int = 0; i < lines.length; ++i)
         {
            var line:String = String(lines[i]);
            var isDate:Boolean = line.indexOf("Начало:\t") == 0 || line.indexOf("Конец:\t") == 0;
            lines[i] = escapeTooltip(line);
            if(isDate)
            {
               var stop:Number = getTooltipDateTabStop();
               if(!isNaN(stop))
               {
                  lines[i] = "<textformat tabstops=\"" + stop + "\">" + lines[i] + "</textformat>";
               }
            }
         }
         return lines.join("<br/>");
      }

      private static function getTooltipDateTabStop() : Number
      {
         if(isNaN(tooltipDateTabStop))
         {
            // ToolTipComplex uses this native body font. Measure the advance
            // through one normal space, without relying on guessed padding.
            var measure:TextField = App.textMgr.createTextField();
            measure.defaultTextFormat = new TextFormat("$FieldFont", 14);
            var prefixes:Array = ["Начало: ", "Конец: "];
            var width:Number = 0;
            for each(var prefix:String in prefixes)
            {
               measure.text = prefix + "0";
               var first:Rectangle = measure.getCharBoundaries(0);
               var date:Rectangle = measure.getCharBoundaries(prefix.length);
               if(first == null || date == null)
               {
                  return NaN;
               }
               width = Math.max(width, date.x - first.x);
            }
            if(width > 0)
            {
               tooltipDateTabStop = Math.ceil(width);
            }
         }
         return tooltipDateTabStop;
      }

      private function hideIconTooltip() : void
      {
         hoverIndex = -1;
         tooltipText = "";
         if(tooltipOwner !== this)
         {
            return;
         }
         tooltipOwner = null;
         try
         {
            App.toolTipMgr.hide();
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] tooltip cleanup: " + error.message);
         }
      }

      private function showNativeTooltip() : void
      {
         // ServerRenderer's private onRollOverHandler cannot be invoked.
         // Preserve its verified tooltip VO without dispatching synthetic
         // rollover events (which also change native state and play sounds).
         var data:Object = getServer();
         var tooltip:Object = data != null ? data.tooltipVo : null;
         try
         {
            if(tooltip != null)
            {
               if(tooltip.isSpecial)
               {
                  App.toolTipMgr.showSpecial.apply(row, [tooltip.specialAlias, null].concat(tooltip.specialArgs));
               }
               else
               {
                  App.toolTipMgr.show(tooltip.tooltip);
               }
            }
            else if(data != null && label != null && label.text != String(data.label))
            {
               App.toolTipMgr.show(String(data.label));
            }
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] native tooltip: " + error.message);
         }
      }

      private function modesFor(data:Object) : Array
      {
         var source:Array = data != null && data.data != "" && servers != null ? servers[data.data] as Array : null;
         var result:Array = [];
         if(source != null)
         {
            for each(var mode:Object in source)
            {
               if(mode != null && mode.icon != null && String(mode.icon) != "")
               {
                  result.push(mode);
                  if(result.length >= 6)
                  {
                     break;
                  }
               }
            }
         }
         return result;
      }

      private function modeKey(modes:Array) : String
      {
         var key:String = "";
         for each(var mode:Object in modes)
         {
            key += String(mode.icon) + (mode.active === false ? ":dim\n" : ":active\n");
         }
         return key;
      }

      private function dataSignature(data:Object) : String
      {
         return data == null ? "" : String(data.data) + "\n" + String(data.label) + "\n" +
            String(data.enabled) + ":" + String(data.haveAccess) + ":" + String(data.csisStatus);
      }

      private function reserveWidth() : Number
      {
         var count:int = reservedColumns();
         if(count == 0)
         {
            return 0;
         }
         // The strip origin is the visible left edge, excluding PNG margins.
         // Native ping text ends before its own bounds by the desired gap.
         return reservedIconWidth() - (isDropdown ? DROPDOWN_PING_OVERHANG : 0);
      }

      private function reservedIconWidth() : Number
      {
         if(reservedColumns() == 0)
         {
            return 0;
         }
         var visibleWidth:Number = isDropdown ? ownIconWidth : columnIconWidth;
         var borderOffset:Number = isDropdown ? DROPDOWN_BORDER_OFFSET : LIST_BORDER_OFFSET;
         return visibleWidth + VISIBLE_GAP - borderOffset;
      }

      // Bundled PNG alpha>=64 bounds, normalized to a 20-unit source square.
      // Transparent margins must not affect artwork height, spacing or hover.
      private static function sourceIconBounds(source:String) : Rectangle
      {
         if(source.indexOf("/frontline.png") >= 0) return new Rectangle(1.5625, 0.3125, 17.1875, 19.6875);
         if(source.indexOf("/rift.png") >= 0) return new Rectangle(2.5, 3, 15, 16);
         if(source.indexOf("/arcade.png") >= 0) return new Rectangle(3, 2.5, 14, 15);
         if(source.indexOf("/battle_royale.png") >= 0) return new Rectangle(3, 3, 14, 15);
         if(source.indexOf("/comp7.png") >= 0) return new Rectangle(2.5, 3, 14.5, 15.5);
         return new Rectangle(1.5, 2, 16, 16);
      }

      private static function iconLeft(source:String) : Number
      {
         var bounds:Rectangle = sourceIconBounds(source);
         return bounds.left * VISIBLE_ICON_HEIGHT / bounds.height;
      }

      private static function iconRight(source:String) : Number
      {
         var bounds:Rectangle = sourceIconBounds(source);
         return bounds.right * VISIBLE_ICON_HEIGHT / bounds.height;
      }

      private static function visibleIconBounds(image:Image) : Rectangle
      {
         var source:String = String(image.source);
         var left:Number = iconLeft(source);
         return new Rectangle(image.x + left, 0, iconRight(source) - left, VISIBLE_ICON_HEIGHT);
      }

      private static function measureColumnWidth(modes:Object, limit:int) : Number
      {
         var widest:Number = 0;
         if(modes == null || limit == 0)
         {
            return widest;
         }
         for each(var entry:Object in modes)
         {
            var items:Array = entry as Array;
            var width:Number = 0;
            var count:int = 0;
            if(items == null)
            {
               continue;
            }
            for each(var mode:Object in items)
            {
               if(mode != null && mode.icon != null && String(mode.icon) != "")
               {
                  var source:String = String(mode.icon);
                  width += iconRight(source) - iconLeft(source) + VISIBLE_GAP;
                  if(++count >= limit)
                  {
                     break;
                  }
               }
            }
            widest = Math.max(widest, count > 0 ? width - VISIBLE_GAP : 0);
         }
         return widest;
      }

      private function reservedColumns() : int
      {
         // Only popup rows share the widest icon strip. The selected server
         // packs its own icons against the dropdown arrow, with no empty slot.
         return isDropdown ? images.length : columns;
      }

      private function nativePingX() : Number
      {
         return int(row.width - ping.width - (isDropdown ? 21 : 2));
      }

      private function nativeWaitingX() : Number
      {
         return isDropdown ? row.width - (waiting.width >> 1) - 21 - 3 :
            row.width - (waiting.width >> 1) - 5;
      }

      private function setX(target:DisplayObject, value:Number) : void
      {
         if(target != null && target.x != value)
         {
            target.x = value;
         }
      }

      private function differs(current:Object, previous:Object) : Boolean
      {
         if(previous == null)
         {
            return true;
         }
         for(var key:String in current)
         {
            if(current[key] !== previous[key])
            {
               return true;
            }
         }
         return false;
      }

      private function snapshot() : Object
      {
         return {
            pingRef: ping, waitingRef: waiting, labelRef: label,
            alertRef: alert, blockRef: block,
            pingX: ping.x,
            waitingX: waiting.x,
            labelWidth: label.width,
            labelHtml: label.htmlText,
            alertX: alert != null ? alert.x : 0,
            blockX: block != null ? block.x : 0
         };
      }

      private function captureNative(current:Object) : void
      {
         if(original == null)
         {
            original = {};
         }
         for(var key:String in current)
         {
            // A native layout may replace only some timeline fields. Keep
            // the baseline of untouched fields carrying our applied value.
            var owner:String = key.indexOf("ping") == 0 ? "pingRef" :
               (key.indexOf("waiting") == 0 ? "waitingRef" :
               (key.indexOf("label") == 0 ? "labelRef" :
               (key.indexOf("alert") == 0 ? "alertRef" : "blockRef")));
            if(applied == null || current[owner] != applied[owner] || current[key] !== applied[key])
            {
               original[key] = current[key];
               if(key == "labelWidth")
               {
                  // Remember the geometry that produced the native width.
                  // If the gutter is disabled during a resize, the current
                  // field may still carry our old narrower applied width.
                  original.labelRowWidth = row.width;
                  original.labelNativeX = label.x;
               }
            }
         }
         // Logical width and auto-sized ping width may change before CLIK
         // performs its next native layout. Absolute anchors never accumulate.
         original.pingX = nativePingX();
         original.waitingX = nativeWaitingX();
      }

      private function restoreLayout() : void
      {
         if(applied == null || original == null)
         {
            return;
         }
         // Restore only fields still carrying our own last value; a native
         // synchronous update or another mod may already have changed them.
         if(ping != null && ping === applied.pingRef && ping.x == applied.pingX)
         {
            setX(ping, nativePingX());
         }
         if(waiting != null && waiting === applied.waitingRef && waiting.x == applied.waitingX)
         {
            setX(waiting, nativeWaitingX());
         }
         if(label != null && label === applied.labelRef)
         {
            if(label.width == applied.labelWidth)
            {
               var nativeWidth:Number = original.labelWidth +
                  (row.width - original.labelRowWidth) -
                  (label.x - original.labelNativeX);
               nativeWidth = Math.max(0, nativeWidth);
               if(label.width != nativeWidth)
               {
                  label.width = nativeWidth;
               }
            }
            if(label.htmlText == applied.labelHtml)
            {
               // Provider UPDATE_ITEM can change the label without native
               // draw updating HTML first. Restore from the current VO after
               // releasing our width limit, rather than an older HTML copy.
               var data:Object = getServer();
               if(data != null)
               {
                  App.utils.commons.truncateTextFieldText(label, String(data.label));
               }
               else if(label.htmlText != original.labelHtml)
               {
                  label.htmlText = original.labelHtml;
               }
            }
         }
         applied = original = lastInput = null;
      }

      private function statusRight() : Number
      {
         if(ping.visible)
         {
            return visiblePingLeft() - VISIBLE_GAP;
         }
         if(waiting.visible)
         {
            return waiting.getBounds(row).left - VISIBLE_GAP;
         }
         return row.width - 2 - reserveWidth() - PING_VISIBLE_RIGHT_INSET;
      }

      private function visiblePingLeft() : Number
      {
         // Native popup ping is right-aligned inside a wider text field.
         // Character bounds include its actual alignment, unlike field bounds.
         var text:String = ping.text;
         var index:int = 0;
         while(index < text.length && (text.charAt(index) == " " ||
            text.charAt(index) == "\t" || text.charAt(index) == "\r" || text.charAt(index) == "\n"))
         {
            ++index;
         }
         if(index < text.length)
         {
            var bounds:Rectangle = ping.getCharBoundaries(index);
            if(bounds != null && bounds.width > 0)
            {
               var point:Point = ping.localToGlobal(new Point(bounds.left, bounds.top));
               return row.globalToLocal(point).x;
            }
         }
         // No usable character (for example, an image-only HTML value).
         return ping.getBounds(row).left;
      }

      private function updateStatusLayout() : void
      {
         var right:Number = statusRight();
         moveStatus(alert, "alertIcon", 4, right);
         if(alert != null && alert.visible)
         {
            right = alert.getBounds(row).left - VISIBLE_GAP;
         }
         moveStatus(block, "blockIcon", 6, right);
      }

      private function moveStatus(icon:DisplayObject, key:String, offset:int, right:Number) : void
      {
         var owned:Object = statusMoves[key];
         if(owned != null && owned.ref !== icon)
         {
            restoreStatus(key, offset);
            owned = null;
         }
         if(icon == null || !icon.visible)
         {
            restoreStatus(key, offset);
            return;
         }
         var delta:Number = right - icon.getBounds(row).right;
         if(Math.abs(delta) < 0.001)
         {
            return;
         }
         if(owned == null)
         {
            owned = {ref: icon, originalX: icon.x, appliedX: icon.x};
            statusMoves[key] = owned;
         }
         else if(icon.x != owned.appliedX)
         {
            owned.originalX = icon.x;
         }
         icon.x += delta;
         owned.appliedX = icon.x;
         ++statusUpdates;
      }

      private function restoreStatus(key:String, offset:int) : void
      {
         var owned:Object = statusMoves[key];
         if(owned == null)
         {
            return;
         }
         var icon:DisplayObject = owned.ref as DisplayObject;
         try
         {
            if(icon != null && icon.x == owned.appliedX)
            {
               var current:TextField = row != null ? Object(row).textField as TextField : null;
               icon.x = row != null && Object(row)[key] === icon && current != null ?
                  int(current.x + current.textWidth) + offset : owned.originalX;
            }
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] status cleanup: " + error.message);
         }
         delete statusMoves[key];
      }

      private function onlineFor(data:Object) : String
      {
         return data != null && online != null && online.hasOwnProperty(String(data.data)) &&
            online[data.data] != null ? String(online[data.data]) : "";
      }

      private function updateOnlineLayout(data:Object) : void
      {
         var text:String = onlineFor(data);
         if(text == "")
         {
            clearOnline();
            onlineDirty = false;
            return;
         }
         if(onlineField == null)
         {
            onlineField = new TextField();
            onlineField.name = "nidinServerOnline";
            onlineField.autoSize = TextFieldAutoSize.LEFT;
            onlineField.selectable = false;
            onlineField.mouseEnabled = false;
            onlineField.mouseWheelEnabled = false;
            onlineField.tabEnabled = false;
            onlineField.multiline = false;
            onlineField.wordWrap = false;
            row.addChild(onlineField);
         }
         if(onlineLabel !== label)
         {
            var format:TextFormat = label.getTextFormat();
            if(format.size != null)
            {
               format.size = Math.max(8, Number(format.size) - 2);
            }
            format.color = 0x96988D;
            onlineField.embedFonts = label.embedFonts;
            onlineField.antiAliasType = label.antiAliasType;
            onlineField.defaultTextFormat = format;
            onlineField.setTextFormat(format);
            onlineLabel = label;
         }
         if(onlineField.text != text)
         {
            onlineField.text = text;
         }
         var x:Number = Math.ceil(label.x + label.textWidth + LABEL_GAP);
         var y:Number = label.y + (label.height - onlineField.height) / 2;
         setX(onlineField, x);
         if(onlineField.y != y)
         {
            onlineField.y = y;
         }
         var limit:Number = row.width - 2 - reserveWidth() - PING_VISIBLE_RIGHT_INSET;
         if(ping.visible)
         {
            limit = Math.min(limit, visiblePingLeft() - LABEL_GAP);
         }
         if(waiting.visible)
         {
            limit = Math.min(limit, waiting.getBounds(row).left - LABEL_GAP);
         }
         if(alert != null && alert.visible)
         {
            limit = Math.min(limit, alert.getBounds(row).left - LABEL_GAP);
         }
         if(block != null && block.visible)
         {
            limit = Math.min(limit, block.getBounds(row).left - LABEL_GAP);
         }
         onlineCandidateRight = x + onlineField.width;
         var shown:Boolean = row.visible && onlineCandidateRight <= limit;
         if(onlineField.visible != shown)
         {
            onlineField.visible = shown;
         }
         onlineDirty = false;
      }

      private function clearOnline() : void
      {
         if(onlineField != null && onlineField.parent != null)
         {
            onlineField.parent.removeChild(onlineField);
         }
         onlineField = onlineLabel = null;
         onlineCandidateRight = NaN;
      }

      private function updateImages(modes:Array) : void
      {
         var cursor:Number = 0;
         for(var i:int = 0; i < modes.length; ++i)
         {
            var image:Image = i < images.length ? images[i] as Image : null;
            var source:String = String(modes[i].icon);
            var targetX:Number = cursor - iconLeft(source);
            cursor += iconRight(source) - iconLeft(source) + VISIBLE_GAP;
            var targetAlpha:Number = modes[i].active === false ? 0.35 : 1;
            if(image != null && image.source == source)
            {
               setX(image, targetX);
               if(image.alpha != targetAlpha)
               {
                  image.alpha = targetAlpha;
               }
               continue;
            }
            if(image != null)
            {
               disposeImage(image);
            }
            image = new Image();
            image.mouseEnabled = false;
            image.mouseChildren = false;
            image.tabEnabled = false;
            image.smoothing = true;
            image.name = "nidinServerModeIcon" + i;
            image.alpha = targetAlpha;
            image.addEventListener(Event.CHANGE, onImageChanged, false, 0, true);
            image.x = targetX;
            images[i] = image;
            strip.addChild(image);
            image.source = source;
            sizeImage(image);
            ++imageLoads;
         }
         for(i = modes.length; i < images.length; ++i)
         {
            disposeImage(images[i] as Image);
         }
         images.length = modes.length;
         ownIconWidth = Math.max(0, cursor - VISIBLE_GAP);
      }

      private function onImageChanged(event:Event) : void
      {
         sizeImage(event.currentTarget as Image);
         if(!disposed)
         {
            updateIconTooltip(modesFor(getServer()), false);
         }
      }

      private function sizeImage(image:Image) : void
      {
         if(image != null && image.ready && image.bitmapWidth > 0 && image.bitmapHeight > 0)
         {
            // Image loads asynchronously and initially has zero dimensions.
            var bounds:Rectangle = sourceIconBounds(String(image.source));
            var factor:Number = VISIBLE_ICON_HEIGHT / bounds.height;
            var sx:Number = ICON_SIZE * factor / image.bitmapWidth;
            var sy:Number = ICON_SIZE * factor / image.bitmapHeight;
            if(image.scaleX != sx)
            {
               image.scaleX = sx;
            }
            if(image.scaleY != sy)
            {
               image.scaleY = sy;
            }
            image.y = -bounds.top * factor;
         }
      }

      private function clearImages() : void
      {
         for each(var image:Image in images)
         {
            disposeImage(image);
         }
         images = [];
         ownIconWidth = 0;
      }

      private function disposeImage(image:Image) : void
      {
         if(image == null)
         {
            return;
         }
         image.removeEventListener(Event.CHANGE, onImageChanged);
         if(image.parent != null)
         {
            image.parent.removeChild(image);
         }
         try
         {
            image.dispose();
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] image cleanup: " + error.message);
         }
      }
   }
}
