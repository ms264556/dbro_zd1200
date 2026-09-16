;(function(){
var targetHash="#zd1200_network_monitor";
var frameId="zd1200-ping-monitor-frame";
var panelVersion="zd1200-ping-monitor-content-v4";
var mounted=false;
var originalTitle=document.title;
function isTarget(){return window.location.hash===targetHash;}
function pingMenuItem(){
    var titles=document.querySelectorAll(".rks-menulist__title");
    for(var i=0;i<titles.length;i++){
        if((titles[i].textContent||"").replace(/^\s+|\s+$/g,"")==="Network Monitor"){
            var item=titles[i];
            while(item&&item.tagName!=="LI")item=item.parentNode;
            return item;
        }
    }
    return null;
}
function markPingActive(){
    var ping=pingMenuItem();
    if(!ping)return;
    var active=document.querySelectorAll("li.rks-menulist__menu--active");
    for(var i=0;i<active.length;i++){
        if(active[i]!==ping)active[i].classList.remove("rks-menulist__menu--active");
    }
    ping.classList.add("rks-menulist__menu--active");
}
function sizeFrame(main,frame){
    var top=main.getBoundingClientRect().top;
    frame.style.height=Math.max(320,window.innerHeight-Math.max(0,top))+"px";
}
function mountPingMonitor(){
    if(!isTarget()||!document.body)return;
    var main=document.getElementById("main-content");
    if(!main)return;
    var frame=document.getElementById(frameId);
    if(!frame||frame.parentNode!==main){
        while(main.firstChild)main.removeChild(main.firstChild);
        main.style.paddingTop="0";
        main.style.paddingRight="0";
        main.style.minHeight="0";
        main.style.background="#fafafa";
        frame=document.createElement("iframe");
        frame.id=frameId;
        frame.title="Network Monitor";
        frame.src="/admin10/zd1200-network-monitor.html?ui=7";
        frame.style.cssText="display:block;position:static;width:100%;border:0;background:#fafafa;";
        main.appendChild(frame);
    }
    mounted=true;
    document.title="Network Monitor - ZoneDirector";
    sizeFrame(main,frame);
    markPingActive();
}
function hashChanged(){
    if(isTarget())mountPingMonitor();
    else if(mounted){
        document.title=originalTitle;
        window.location.reload();
    }
}
window.addEventListener("hashchange",hashChanged,false);
window.addEventListener("resize",mountPingMonitor,false);
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",mountPingMonitor,false);
else mountPingMonitor();
window.setInterval(mountPingMonitor,250);
})();
