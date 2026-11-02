export const PDF_MAX_BYTES = 5 * 1024 * 1024;
export function applicationEmail(value) {
  const email = String(value || '').trim();
  return email.length <= 254 && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(email) ? email : '';
}
export function employerEmailLink(job) {
  const email = applicationEmail(job.application_email);
  return email ? 'mailto:' + encodeURIComponent(email) + '?subject=' + encodeURIComponent('Application: ' + job.title + ' — ' + job.company_name) + '&body=' + encodeURIComponent('Hello ' + job.company_name + ',\n\nI would like to apply for ' + job.title + ', advertised on AJM JobZone.\n\nPlease find my application attached.\n\nKind regards,\n') : '';
}
export async function validateApplicationPdf(file) {
  if (!file || !/\.pdf$/i.test(file.name) || !['', 'application/pdf'].includes(file.type)) throw new Error('Choose a PDF application form.');
  if (!file.size || file.size > PDF_MAX_BYTES) throw new Error('Your PDF must be between 1 byte and 5 MB.');
  const header = new Uint8Array(await file.slice(0, 5).arrayBuffer());
  if (new TextDecoder().decode(header) !== '%PDF-') throw new Error('This file is not a valid PDF. Please export it as PDF and try again.');
  return file;
}
export function applicationFilename(value) {
  const clean = String(value || 'application.pdf').replace(/[^a-zA-Z0-9 ._()-]/g, '_').slice(0, 180);
  return /\.pdf$/i.test(clean) ? clean : clean + '.pdf';
}
