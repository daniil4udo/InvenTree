import { expect, test } from './baseFixtures.js';
import { activateTableView, loadTab } from './helpers.js';
import { doCachedLogin } from './login.js';
import { setPluginState } from './settings.js';

/*
 * Test for label printing.
 * Select a number of stock items from the table,
 * and print labels against them
 */
test('Label Printing', async ({ browser }) => {
  const page = await doCachedLogin(browser, { url: 'stock/location/index/' });

  await page.waitForURL('**/web/stock/location/**');

  await loadTab(page, 'Stock Items');

  // Select some labels
  await page.getByLabel('Select record 1', { exact: true }).click();
  await page.getByLabel('Select record 2', { exact: true }).click();
  await page.getByLabel('Select record 3', { exact: true }).click();

  await page
    .getByLabel('Stock Items')
    .getByLabel('action-menu-printing-actions')
    .click();
  await page.getByLabel('action-menu-printing-actions-print-labels').click();

  // Select plugin
  await page.getByLabel('related-field-plugin').click();
  await page.getByText('InvenTreeLabelMachine').last().click();

  // Select label template
  await page.getByLabel('related-field-template').click();
  await page
    .getByRole('option', { name: 'InvenTree Stock Item Label' })
    .click();

  await page.getByLabel('related-field-plugin').click();
  await page.getByRole('option', { name: 'InvenTreeLabel provides' }).click();

  // Submit the print form (second time should result in success)
  await page.getByRole('button', { name: 'Print', exact: true }).isEnabled();
  await page.getByRole('button', { name: 'Print', exact: true }).click();

  await page.getByText('Process completed successfully').first().waitFor();
  await page.context().close();
});

/*
 * Test for report printing
 * Navigate to a PurchaseOrder detail page,
 * and print a report against it.
 */
test('Report Printing', async ({ browser }) => {
  const page = await doCachedLogin(browser, { url: 'stock/location/index/' });

  await page.waitForURL('**/web/stock/location/**');

  // Navigate to a specific PurchaseOrder
  await page.getByRole('tab', { name: 'Purchasing' }).click();
  await loadTab(page, 'Purchase Orders');
  await activateTableView(page);

  await page.getByRole('cell', { name: 'PO0009' }).click();

  // Select "print report"
  await page.getByLabel('action-menu-printing-actions').click();
  await page.getByLabel('action-menu-printing-actions-print-reports').click();

  // Select template
  await page.getByLabel('related-field-template').click();
  await page.getByRole('option', { name: 'InvenTree Purchase Order' }).click();

  // Submit the print form (should result in success)
  await page.getByRole('button', { name: 'Print', exact: true }).isEnabled();
  await page.getByRole('button', { name: 'Print', exact: true }).click();

  await page.getByText('Process completed successfully').first().waitFor();
  await page.context().close();
});

test('Report Editing', async ({ browser, request }) => {
  const page = await doCachedLogin(browser, {
    username: 'admin',
    password: 'inventree'
  });

  // activate the sample plugin for this test
  await setPluginState({
    request,
    plugin: 'sampleui',
    state: true
  });

  // Navigate to the admin center
  await page.getByRole('button', { name: 'admin' }).click();
  await page.getByRole('menuitem', { name: 'Admin Center' }).click();
  await loadTab(page, 'Label Templates');
  await page
    .getByRole('cell', { name: 'InvenTree Stock Item Label (' })
    .click();

  // Generate preview
  await page.getByLabel('split-button-preview-options-action').click();
  await page
    .getByLabel('split-button-preview-options-item-preview-save', {
      exact: true
    })
    .click();

  await page.getByRole('button', { name: 'Save & Reload' }).click();

  await page.getByText('The preview has been updated').waitFor();

  // Test plugin provided editors
  await page.getByRole('tab', { name: 'Sample Template Editor' }).click();
  const textarea = page.locator('#sample-template-editor-textarea');
  const textareaValue = await textarea.inputValue();
  expect(textareaValue).toContain(
    `<img class='qr' alt="{% trans 'QR Code' %}" src='{% qrcode qr_data %}'>`
  );
  textarea.fill(`${textareaValue}\nHello world`);

  // Switch back and forth to see if the changed contents get correctly passed between the hooks
  await page.getByRole('tab', { name: 'Code', exact: true }).click();
  await page.getByRole('tab', { name: 'Sample Template Editor' }).click();
  const newTextareaValue = await page
    .locator('#sample-template-editor-textarea')
    .inputValue();
  expect(newTextareaValue).toMatch(/\nHello world$/);

  // Test plugin provided previews
  await page.getByRole('tab', { name: 'Sample Template Preview' }).click();
  await page.getByRole('heading', { name: 'Hello world' }).waitFor();
  const consoleLogPromise = page.waitForEvent('console');
  await page
    .getByLabel('split-button-preview-options', { exact: true })
    .click();
  const msg = (await consoleLogPromise).args();
  expect(await msg[0].jsonValue()).toBe('updatePreview');
  expect(await msg[1].jsonValue()).toBe(newTextareaValue);

  // deactivate the sample plugin again after the test
  await setPluginState({
    request,
    plugin: 'sampleui',
    state: false
  });
});
