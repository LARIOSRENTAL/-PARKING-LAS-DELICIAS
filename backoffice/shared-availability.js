/* Server-derived availability shared by reservations, space changes and rotation. */
let parkingFreeStaySpotIds=new Set(),parkingFreeStaySpotsReady=false;
async function refreshSharedStayAvailability(){parkingFreeStaySpotsReady=false;const r=await db.rpc('parking_available_stay_spots');if(r.error){parkingFreeStaySpotIds=new Set();throw Error('No se pudieron comprobar las plazas libres: '+r.error.message)}parkingFreeStaySpotIds=new Set(r.data||[]);parkingFreeStaySpotsReady=true}
freeSpotsFor=function(typeId){return parkingFreeStaySpotsReady?spots.filter(s=>parkingFreeStaySpotIds.has(s.id)&&spotFitsVehicle(s,typeId)):[]};
const loadReservationsBeforeSharedAvailability=loadReservations;
loadReservations=async function(){try{await refreshSharedStayAvailability()}catch(e){console.error(e);const el=opsEl('reservationsBody');if(el)el.textContent=e.message;return}await loadReservationsBeforeSharedAvailability()};
const moveActiveStayBeforeSharedAvailability=moveActiveStay;
moveActiveStay=async function(id){try{await refreshSharedStayAvailability();await moveActiveStayBeforeSharedAvailability(id)}catch(e){alert(e.message)}};
