// Single customer copy; the internal receipt is deliberately absent from emailed PDFs.
export async function buildInvoicePdf(invoice,lib,logoBytes){
 const {PDFDocument,StandardFonts,rgb}=lib,doc=await PDFDocument.create(),page=doc.addPage([595.28,841.89]),mm=v=>v*72/25.4;
 const times=await doc.embedFont(StandardFonts.TimesRoman),bold=await doc.embedFont(StandardFonts.TimesRomanBold),arial=await doc.embedFont(StandardFonts.Helvetica),arialBold=await doc.embedFont(StandardFonts.HelveticaBold),ink=rgb(.06,.06,.06),gray=rgb(.88,.88,.88),logo=await doc.embedPng(logoBytes);
 const x=mm(14),right=mm(196),width=right-x;
 const draw=(text,xx,y,font=times,size=10)=>page.drawText(String(text??''),{x:xx,y,font,size,color:ink});
 const wrap=(text,font,size,max)=>{const lines=[];for(const paragraph of String(text||'').split(/\n/)){let line='';for(const word of paragraph.split(/\s+/)){if(!word)continue;const next=line?line+' '+word:word;if(font.widthOfTextAtSize(next,size)>max&&line){lines.push(line);line=word}else line=next}lines.push(line)}return lines};
 ['Aparcamientos Las Delicias Málaga S.L.','C/Don Rodrigo, 3','N.I.F. B93368256','29008 -MALAGA-'].forEach((v,i)=>draw(v,x,mm(280)-i*12,bold,10));
 const logoWidth=mm(78),logoHeight=logoWidth*logo.height/logo.width;page.drawImage(logo,{x:right-logoWidth,y:mm(285)-logoHeight,width:logoWidth,height:logoHeight});
 const date=new Date(invoice.issued_at).toLocaleDateString('es-ES',{timeZone:'Europe/Madrid'}),address=wrap('Domicilio: '+invoice.customer_address,times,9.5,mm(115)),name=wrap('Cliente: '+invoice.customer_name,times,9.5,mm(115));
 const top=mm(250),boxHeight=Math.max(mm(24),(address.length+name.length+1)*12+14);page.drawRectangle({x,y:top-boxHeight,width,height:boxHeight,color:gray,borderColor:rgb(.3,.3,.3),borderWidth:.6});
 let y=top-14;draw('Factura: '+invoice.number,x+8,y,times,9.5);y-=12;for(const line of name){draw(line,x+8,y,times,9.5);y-=12}for(const line of address){draw(line,x+8,y,times,9.5);y-=12}
 draw('Fecha: '+date,right-mm(49),top-14,times,9.5);draw('N.I.F.: '+invoice.customer_tax_id,right-mm(49),top-26,times,9.5);draw('C.P.: '+(String(invoice.customer_address||'').match(/\b\d{5}\b/)?.[0]||''),right-mm(49),top-38,times,9.5);
 const month=new Date(invoice.billing_month+'T12:00:00Z').toLocaleDateString('es-ES',{month:'long',year:'numeric'}),description='Importe correspondiente al alquiler de Parking para el vehículo '+(invoice.vehicle||'')+' matrícula '+(invoice.plate||'')+' durante el mes de '+month;
 wrap(description,arial,10,mm(145)).forEach((line,i)=>draw(line,x+mm(18),top-boxHeight-mm(23)-i*15,arial,10));
 const totals=[['PRECIO',invoice.amount_before_vat],['DTO.',invoice.discount_eur],['I.V.A. 21%',invoice.vat_eur],['TOTAL',invoice.total_eur]],column=width/4,base=mm(82),height=mm(12);
 totals.forEach(([label,amount],i)=>{const xx=x+i*column;page.drawRectangle({x:xx,y:base,width:column,height,color:gray,borderColor:rgb(.3,.3,.3),borderWidth:.6});draw(label,xx+6,base+13,arial,9);const value=Number(amount||0).toLocaleString('es-ES',{minimumFractionDigits:2,maximumFractionDigits:2});draw(value,xx+column-arialBold.widthOfTextAtSize(value,10)-6,base+13,arialBold,10)});
 doc.setTitle('Factura '+invoice.number);doc.setAuthor('Parking Las Delicias');return doc.save();
}
