package
{
   import flash.display.DisplayObject;
   import flash.display.DisplayObjectContainer;
   import flash.display.MovieClip;
   import flash.events.Event;
   import flash.events.IEventDispatcher;
   import flash.utils.Dictionary;
   import flash.utils.getQualifiedClassName;
   import net.wg.data.constants.generated.LAYER_NAMES;
   import net.wg.gui.components.controls.events.DropdownMenuEvent;
   import net.wg.infrastructure.base.AbstractView;
   import net.wg.infrastructure.events.LifeCycleEvent;
   import net.wg.infrastructure.events.LoaderEvent;
   import net.wg.infrastructure.interfaces.IManagedContainer;
   import net.wg.infrastructure.interfaces.IManagedContent;
   import net.wg.infrastructure.managers.impl.ContainerManagerBase;
   import nidin.server_mode_icons.ServerRowIcons;
   import nidin.server_mode_icons.ServerDropDownStatus;
   import nidin.server_mode_icons.ServerDropDownWidth;

   /** An empty DAAPI bridge. Decorations belong to the native server rows. */
   public class NidinServerModeIconsUI extends AbstractView
   {
      public var onBridgeReady:Function;
      public var onServerListOpening:Function;

      private var servers:Object = {};
      private var online:Object = {};
      private var columns:int = 0;
      private var rows:Dictionary = new Dictionary();
      private var statuses:Dictionary = new Dictionary();
      private var sizes:Dictionary = new Dictionary();
      private var roots:Dictionary = new Dictionary();
      private var stacks:Dictionary = new Dictionary();
      private var menus:Dictionary = new Dictionary();
      private var manager:ContainerManagerBase;
      private var listening:Boolean = false;
      private var disposing:Boolean = false;

      public function NidinServerModeIconsUI()
      {
         super();
         mouseEnabled = false;
         mouseChildren = false;
         tabEnabled = false;
      }

      public function as_setModes(payload:Object) : void
      {
         servers = payload != null && payload.servers != null ? payload.servers : {};
         online = payload != null && payload.online != null ? payload.online : {};
         columns = payload != null ? Math.max(0, Math.min(6, int(payload.columnCount))) : 0;
         for each(var decoration:ServerRowIcons in rows)
         {
            decoration.setModes(servers, columns);
            decoration.setOnline(online);
         }
         for each(var size:ServerDropDownWidth in sizes)
         {
            size.setContent(servers, columns, online);
         }
      }

      /** Small read-only lifecycle diagnostics; inspect only registered keys. */
      public function as_getDiagnostics() : Object
      {
         var result:Object = {
            rowCount: 0, rootCount: 0, stackCount: 0, menuCount: 0,
            serverCount: 0, columnCount: columns, rowTypes: {}, rootTypes: {}, rowState: [],
            statusCount: 0, statusTypes: {}, statusState: [], sizeCount: 0, sizeState: []
         };
         var key:Object;
         var type:String;
         for(key in rows)
         {
            ++result.rowCount;
            type = getQualifiedClassName(key);
            result.rowTypes[type] = int(result.rowTypes[type]) + 1;
            if(result.rowState.length < 16)
            {
               result.rowState.push(ServerRowIcons(rows[key]).as_getDiagnostics());
            }
         }
         for(key in roots)
         {
            ++result.rootCount;
            type = getQualifiedClassName(key);
            result.rootTypes[type] = int(result.rootTypes[type]) + 1;
         }
         for(key in statuses)
         {
            ++result.statusCount;
            type = getQualifiedClassName(key);
            result.statusTypes[type] = int(result.statusTypes[type]) + 1;
            if(result.statusState.length < 16)
            {
               result.statusState.push(ServerDropDownStatus(statuses[key]).as_getDiagnostics());
            }
         }
         for(key in stacks)
         {
            ++result.stackCount;
         }
         for(key in sizes)
         {
            ++result.sizeCount;
            if(result.sizeState.length < 16)
            {
               result.sizeState.push(ServerDropDownWidth(sizes[key]).as_getDiagnostics());
            }
         }
         for(key in menus)
         {
            ++result.menuCount;
         }
         for(key in servers)
         {
            ++result.serverCount;
         }
         return result;
      }

      override protected function onPopulate() : void
      {
         super.onPopulate();
         manager = App.containerMgr as ContainerManagerBase;
         if(manager != null)
         {
            manager.loader.addEventListener(LoaderEvent.VIEW_LOADED, onViewLoaded, false, 0, true);
         }
         // Dropdown events bubble from the native button. Popup renderers are
         // siblings of that button, so its own subtree cannot discover them.
         App.stage.addEventListener(DropdownMenuEvent.SHOW_DROP_DOWN, onDropDownShown, false, 0, true);
         App.stage.addEventListener(DropdownMenuEvent.CLOSE_DROP_DOWN, onDropDownClosed, false, 0, true);
         listening = true;
         for each(var layer:String in [LAYER_NAMES.VIEWS, LAYER_NAMES.WINDOWS, LAYER_NAMES.FULLSCREEN_WINDOWS])
         {
            var container:DisplayObjectContainer = App.containerMgr.getContainer(
               LAYER_NAMES.LAYER_ORDER.indexOf(layer)) as DisplayObjectContainer;
            if(container == null)
            {
               continue;
            }
            for(var i:int = 0; i < container.numChildren; ++i)
            {
               var content:IManagedContent = container.getChildAt(i) as IManagedContent;
               if(content != null)
               {
                  watchRoot(content.sourceView as DisplayObjectContainer);
               }
            }
         }
      }

      override protected function nextFrameAfterPopulateHandler() : void
      {
         super.nextFrameAfterPopulateHandler();
         leaveModalFocus();
         if(parent != App.instance)
         {
            // Remove explicitly so the managed container drops its focus
            // listeners before Flash attaches the bridge to App.
            if(parent is IManagedContainer)
            {
               parent.removeChild(this);
            }
            DisplayObjectContainer(App.instance).addChild(this);
         }
         App.containerMgr.updateFocus();
         if(onBridgeReady != null)
         {
            onBridgeReady();
         }
      }

      override protected function onDispose() : void
      {
         disposing = true;
         if(listening)
         {
            if(manager != null)
            {
               manager.loader.removeEventListener(LoaderEvent.VIEW_LOADED, onViewLoaded);
            }
            App.stage.removeEventListener(DropdownMenuEvent.SHOW_DROP_DOWN, onDropDownShown);
            App.stage.removeEventListener(DropdownMenuEvent.CLOSE_DROP_DOWN, onDropDownClosed);
            listening = false;
         }
         var rootList:Array = [];
         var rowList:Array = [];
         var statusList:Array = [];
         var root:DisplayObjectContainer;
         for(var key:Object in roots)
         {
            rootList.push(key);
         }
         for each(root in rootList)
         {
            unwatchRoot(root);
         }
         for each(var decoration:ServerRowIcons in rows)
         {
            rowList.push(decoration);
         }
         for each(decoration in rowList)
         {
            disposeDecoration(decoration);
         }
         for each(var status:ServerDropDownStatus in statuses)
         {
            statusList.push(status);
         }
         for each(status in statusList)
         {
            disposeStatus(status);
         }
         rows = new Dictionary();
         statuses = new Dictionary();
         sizes = new Dictionary();
         menus = new Dictionary();
         servers = {};
         online = {};
         columns = 0;
         manager = null;
         onBridgeReady = null;
         onServerListOpening = null;
         super.onDispose();
      }

      private function onViewLoaded(event:LoaderEvent) : void
      {
         watchRoot(event.view as DisplayObjectContainer);
      }

      private function watchRoot(root:DisplayObjectContainer) : void
      {
         if(root == null || root == this || roots[root] || disposing)
         {
            return;
         }
         roots[root] = true;
         root.addEventListener(Event.ADDED, onChildAdded, false, 0, true);
         root.addEventListener(Event.REMOVED_FROM_STAGE, onRootRemoved, false, 0, true);
         root.addEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onRootRemoved, false, 10000, true);
         // Login forms are cached and switched without a new VIEW_LOADED.
         // These names are public LoginPage/LoginViewStack API in the client.
         if("loginViewStack" in root && Object(root).loginViewStack != null)
         {
            var stack:IEventDispatcher = Object(root).loginViewStack as IEventDispatcher;
            if(stack != null)
            {
               stacks[root] = stack;
               stack.addEventListener("view_changed", onLoginViewChanged, false, 0, true);
               inspectLoginForm(Object(stack).currentView);
            }
         }
         scan(root);
      }

      private function unwatchRoot(root:DisplayObjectContainer) : void
      {
         if(root == null || !roots[root])
         {
            return;
         }
         root.removeEventListener(Event.ADDED, onChildAdded);
         root.removeEventListener(Event.REMOVED_FROM_STAGE, onRootRemoved);
         root.removeEventListener(LifeCycleEvent.ON_BEFORE_DISPOSE, onRootRemoved);
         var stack:IEventDispatcher = stacks[root] as IEventDispatcher;
         if(stack != null)
         {
            stack.removeEventListener("view_changed", onLoginViewChanged);
         }
         delete stacks[root];
         delete roots[root];
         // A popup can be disposed without CLOSE_DROP_DOWN. There is no
         // decorator on its button now, so release that association here.
         var closedButtons:Array = [];
         for(var button:Object in menus)
         {
            if(menus[button] === root || root.contains(button as DisplayObject))
            {
               closedButtons.push(button);
            }
         }
         for each(button in closedButtons)
         {
            var popup:DisplayObjectContainer = menus[button] as DisplayObjectContainer;
            delete menus[button];
            if(popup != root)
            {
               unwatchRoot(popup);
            }
         }
         // A view may dispose cached, hidden forms before removing them.
         var descendants:Array = [];
         for(var key:Object in rows)
         {
            if(root.contains(key as DisplayObject))
            {
               descendants.push(rows[key]);
            }
         }
         for each(var decoration:ServerRowIcons in descendants)
         {
            disposeDecoration(decoration);
         }
         var statusDescendants:Array = [];
         for(key in statuses)
         {
            if(root.contains(key as DisplayObject))
            {
               statusDescendants.push(statuses[key]);
            }
         }
         for each(var status:ServerDropDownStatus in statusDescendants)
         {
            disposeStatus(status);
         }
      }

      private function disposeDecoration(decoration:ServerRowIcons) : void
      {
         try
         {
            decoration.dispose();
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] row cleanup: " + error.message);
         }
      }

      private function disposeStatus(status:ServerDropDownStatus) : void
      {
         try
         {
            status.dispose();
         }
         catch(error:Error)
         {
            trace("[nidin.server_mode_icons] header cleanup: " + error.message);
         }
      }

      private function onRootRemoved(event:Event) : void
      {
         unwatchRoot(event.currentTarget as DisplayObjectContainer);
      }

      private function onLoginViewChanged(event:Event) : void
      {
         inspectLoginForm(Object(event).view);
      }

      private function inspectLoginForm(form:Object) : void
      {
         if(form is DisplayObject)
         {
            scan(form as DisplayObject);
         }
      }

      private function onChildAdded(event:Event) : void
      {
         var child:DisplayObject = event.target as DisplayObject;
         if(child != null && child.name != ServerRowIcons.STRIP_NAME)
         {
            scan(child);
         }
      }

      private function onDropDownShown(event:DropdownMenuEvent) : void
      {
         if(disposing)
         {
            return;
         }
         var button:MovieClip = ServerRowIcons.isServerDropDown(event.target) ? event.target as MovieClip : null;
         if(button == null || event.dropDownRef == null)
         {
            return;
         }
         attachStatus(button);
         // Refresh prime-time availability immediately before the new popup
         // gets any decorators; Python sends its payload back synchronously.
         if(onServerListOpening != null)
         {
            try
            {
               onServerListOpening();
            }
            catch(error:Error)
            {
               trace("[nidin.server_mode_icons] availability refresh: " + error.message);
            }
         }
         var previous:DisplayObjectContainer = menus[button] as DisplayObjectContainer;
         if(previous != null && previous != event.dropDownRef)
         {
            unwatchRoot(previous);
         }
         menus[button] = event.dropDownRef;
         watchRoot(event.dropDownRef);
         if(!disposing && sizes[button] != null)
         {
            ServerDropDownWidth(sizes[button]).setPopup(event.dropDownRef);
         }
      }

      private function onDropDownClosed(event:DropdownMenuEvent) : void
      {
         var button:MovieClip = ServerRowIcons.isServerDropDown(event.target) ? event.target as MovieClip : null;
         if(button != null)
         {
            if(sizes[button] != null)
            {
               ServerDropDownWidth(sizes[button]).setPopup(null);
            }
            unwatchRoot(menus[button] as DisplayObjectContainer);
            delete menus[button];
         }
      }

      private function scan(start:DisplayObject) : void
      {
         // A bounded, event-driven discovery pass, never a stage frame scan.
         var pending:Array = [start];
         var visits:int = 0;
         while(pending.length > 0 && visits < 2048)
         {
            var node:DisplayObject = pending.pop() as DisplayObject;
            ++visits;
            if(node == null || node == this || node.name == ServerRowIcons.STRIP_NAME)
            {
               continue;
            }
            // Header only moves the native warning; mode icons and online
            // remain confined to popup renderers.
            if(ServerRowIcons.isServerDropDown(node))
            {
               attachStatus(node as MovieClip);
               continue;
            }
            if(ServerRowIcons.isServerRenderer(node))
            {
               attachRow(node as MovieClip);
               continue;
            }
            var container:DisplayObjectContainer = node as DisplayObjectContainer;
            if(container != null)
            {
               for(var i:int = 0; i < container.numChildren; ++i)
               {
                  pending.push(container.getChildAt(i));
               }
            }
         }
      }

      private function attachRow(row:MovieClip) : void
      {
         if(row == null || rows[row] != null || disposing ||
            ServerRowIcons.isServerDropDown(row) || !ServerRowIcons.isServerRenderer(row))
         {
            return;
         }
         var decoration:ServerRowIcons = new ServerRowIcons(row, servers, columns, onRowReleased);
         rows[row] = decoration;
         decoration.setOnline(online);
      }

      private function attachStatus(row:MovieClip) : void
      {
         if(row == null || disposing || !ServerRowIcons.isServerDropDown(row))
         {
            return;
         }
         if(statuses[row] == null)
         {
            statuses[row] = new ServerDropDownStatus(row, onStatusReleased);
         }
         if(sizes[row] == null)
         {
            var size:ServerDropDownWidth = new ServerDropDownWidth(row, measurePopup, onWidthChanged);
            sizes[row] = size;
            size.setContent(servers, columns, online);
         }
      }

      private function onStatusReleased(row:MovieClip) : void
      {
         delete statuses[row];
         var size:ServerDropDownWidth = sizes[row] as ServerDropDownWidth;
         delete sizes[row];
         if(size != null)
         {
            try
            {
               size.dispose();
            }
            catch(error:Error)
            {
               trace("[nidin.server_mode_icons] width disposal: " + error.message);
            }
         }
         unwatchRoot(menus[row] as DisplayObjectContainer);
         delete menus[row];
      }

      private function onRowReleased(row:MovieClip) : void
      {
         delete rows[row];
      }

      private function measurePopup(popup:DisplayObjectContainer) : Object
      {
         var withoutOnline:Number = 0;
         var withOnline:Number = 0;
         var found:Boolean = false;
         for(var key:Object in rows)
         {
            var row:MovieClip = key as MovieClip;
            if(row == null || !popup.contains(row))
            {
               continue;
            }
            var decoration:ServerRowIcons = rows[key] as ServerRowIcons;
            var plain:Number = decoration.requiredWidth(false);
            var full:Number = decoration.requiredWidth(true);
            if(!isNaN(plain) && !isNaN(full))
            {
               var inset:Number = popup.width - row.width;
               withoutOnline = Math.max(withoutOnline, plain + inset);
               withOnline = Math.max(withOnline, full + inset);
               found = true;
            }
         }
         return found ? {withoutOnline: withoutOnline, withOnline: withOnline} : null;
      }

      private function onWidthChanged(button:MovieClip, popup:DisplayObjectContainer) : void
      {
         if(popup != null)
         {
            for(var key:Object in rows)
            {
               if(popup.contains(key as DisplayObject))
               {
                  ServerRowIcons(rows[key]).refreshLayout();
               }
            }
         }
         var status:ServerDropDownStatus = statuses[button] as ServerDropDownStatus;
         if(status != null)
         {
            status.refreshLayout();
         }
      }
   }
}
